// Readiness grade for mirrored vulnerability reports — vendored portal formula.
//
// This is a manual, dependency-free port of the portal's grading path
// (petasus-ai/petasus-image-catalog):
//   src/lib/registry/vuln.ts        parseVulnReport: fold + track classification
//   src/lib/registry/readiness.ts   gradeFromActionable: the two ladders
//   src/lib/registry/grade-summary.ts  summarizeGrade + GRADE_FORMULA_VERSION
// ported from portal commit 0f024c4 (2026-08-10).
//
// The portal remains the canonical source. Vendoring instead of checking the
// portal out was a deliberate trade (the formula is stable and the checkout
// needed a PAT into a private repo): the cost is that a portal change to the
// ladders or to classifyTrack MUST be mirrored here, bumping formulaVersion in
// both places. Verify a sync with the portal's own CLI — `pnpm grade` there and
// this script must produce identical JSON for the same reports.
//
// Fields the portal folds but that never reach GradeSummary (cvss, urls,
// wontfix, installed versions, distroLatest, frozen aggregation) are omitted —
// the output contract, not the internal shape, is what this copy preserves.
//
//   node scripts/grade.mjs <vuln.json> [...]      one JSON object per line
//   node scripts/grade.mjs --pretty <vuln.json>   indented, for humans
//
// Exit 1 if any input failed to parse, 2 on usage error.
import { readFile } from 'node:fs/promises'
import process from 'node:process'

export const GRADE_FORMULA_VERSION = 1

const SEVERITY_ORDER = ['Critical', 'High', 'Medium', 'Low', 'Negligible', 'Unknown']
const SEVERITY_BY_LOWER = new Map(SEVERITY_ORDER.map((level) => [level.toLowerCase(), level]))

// Kernel package names — union of deb and rpm conventions, plus syft's
// kernel-binary cataloger names. Kernel CVEs are a separate over-reported
// track and must never reach the actionable set.
const KERNEL_DEB =
  /^linux-(image|headers|modules|modules-extra|tools|cloud-tools|buildinfo|source)/
const KERNEL_RPM = /^kernel(-|$)/
// Types the image cannot fix with an on-node package manager.
const VENDORED_TYPES = new Set(['go-module', 'binary', 'java-archive', 'npm', 'gem', 'rust-crate'])

function classifyTrack(name, type, vendored) {
  if (name === 'linux' || name === 'linux-kernel' || KERNEL_RPM.test(name) || KERNEL_DEB.test(name)) {
    return 'kernel'
  }
  if (VENDORED_TYPES.has(type)) return 'vendored'
  if (vendored) return 'vendored'
  return 'managed'
}

const asString = (value) =>
  typeof value === 'string' && value.trim() !== '' ? value.trim() : null

function normalizeSeverity(value) {
  const key = typeof value === 'string' ? value.trim().toLowerCase() : ''
  return SEVERITY_BY_LOWER.get(key) ?? 'Unknown'
}

const maxSeverity = (a, b) =>
  SEVERITY_ORDER.indexOf(a) <= SEVERITY_ORDER.indexOf(b) ? a : b

function toIso(value) {
  if (!value) return null
  const time = Date.parse(value)
  return Number.isNaN(time) ? null : new Date(time).toISOString()
}

/** Fold grype matches into unique (track, CVE) findings — portal parseVulnReport. */
function parseVulnReport(data) {
  if (typeof data !== 'object' || data === null) return null
  const document = data
  if (!Array.isArray(document.matches)) return null

  const folded = new Map()
  for (const entry of document.matches) {
    if (typeof entry !== 'object' || entry === null) continue
    const vuln = typeof entry.vulnerability === 'object' ? entry.vulnerability : null
    const artifact = typeof entry.artifact === 'object' ? entry.artifact : null
    const id = asString(vuln?.id)
    const packageName = asString(artifact?.name)
    if (!id || !packageName) continue

    const track = classifyTrack(packageName, asString(artifact?.type) ?? '', artifact?.vendored === true)
    const fix = typeof vuln?.fix === 'object' && vuln.fix !== null ? vuln.fix : null
    const fixState = asString(fix?.state)
    // Tri-state: only an explicit `false` withholds the fix (absent/null keep it).
    const shipped = fix?.availableInDistro !== false

    const key = `${track}\n${id}`
    const finding = folded.get(key) ?? {
      id,
      track,
      severity: 'Unknown',
      fixable: false,
      awaitingDistro: false,
      packages: [],
      fixVersions: [],
    }
    finding.severity = maxSeverity(finding.severity, normalizeSeverity(vuln?.severity))
    if (fixState === 'fixed') {
      if (shipped) finding.fixable = true
      else finding.awaitingDistro = true
    }
    if (!finding.packages.includes(packageName)) finding.packages.push(packageName)
    for (const version of Array.isArray(fix?.versions) ? fix.versions : []) {
      const value = asString(version)
      if (value && !finding.fixVersions.includes(value)) finding.fixVersions.push(value)
    }
    folded.set(key, finding)
  }

  const findings = [...folded.values()].sort(
    (a, b) =>
      SEVERITY_ORDER.indexOf(a.severity) - SEVERITY_ORDER.indexOf(b.severity) ||
      a.id.localeCompare(b.id, 'en'),
  )

  const actionable = findings.filter((f) => f.track === 'managed' && f.fixable)
  const awaitingDistro = findings.filter(
    (f) => f.track === 'managed' && !f.fixable && f.awaitingDistro,
  )
  const noFix = findings.filter((f) => f.track === 'managed' && !f.fixable && !f.awaitingDistro)
  const kernel = findings.filter((f) => f.track === 'kernel')
  const vendored = findings.filter((f) => f.track === 'vendored')

  const bySeverity = Object.fromEntries(SEVERITY_ORDER.map((level) => [level, 0]))
  for (const finding of actionable) bySeverity[finding.severity] += 1

  const descriptor = typeof document.descriptor === 'object' ? document.descriptor : null
  const db = typeof descriptor?.db === 'object' ? descriptor.db : null
  const scannerName = asString(descriptor?.name)
  const scannerVersion = asString(descriptor?.version)

  return {
    actionable,
    awaitingDistro,
    noFix,
    kernel,
    vendored,
    bySeverity,
    scannedAt: toIso(asString(descriptor?.timestamp)),
    dbBuilt: toIso(asString(db?.built)) ?? toIso(asString(descriptor?.timestamp)),
    scanner: scannerName ? `${scannerName} ${scannerVersion ?? ''}`.trim() : null,
  }
}

/** The two ladders, worst wins; A only when both defer — portal readiness.ts. */
function gradeFromActionable(bySeverity) {
  const critical = bySeverity.Critical ?? 0
  const high = bySeverity.High ?? 0
  const criticalGrade =
    critical === 0 ? null : critical <= 2 ? 'C' : critical <= 10 ? 'D' : 'F'
  const highGrade =
    high === 0 ? null : high <= 40 ? 'B' : high <= 100 ? 'C' : high <= 200 ? 'D' : 'F'
  const rank = ['A', 'B', 'C', 'D', 'F']
  const ladders = [criticalGrade, highGrade].filter((grade) => grade !== null)
  if (ladders.length === 0) return 'A'
  return ladders.reduce((worst, grade) =>
    rank.indexOf(grade) > rank.indexOf(worst) ? grade : worst,
  )
}

/** GradeSummary projection — portal grade-summary.ts. */
function summarizeGrade(report) {
  return {
    grade: gradeFromActionable(report.bySeverity),
    formulaVersion: GRADE_FORMULA_VERSION,
    actionable: report.actionable.length,
    bySeverity: report.bySeverity,
    drivers: report.actionable
      .filter((finding) => finding.severity === 'Critical' || finding.severity === 'High')
      .map((finding) => ({
        id: finding.id,
        severity: finding.severity,
        packages: [...finding.packages].sort((a, b) => a.localeCompare(b, 'en')),
        fixVersions: [...finding.fixVersions],
      })),
    awaitingDistro: report.awaitingDistro.length,
    noFix: report.noFix.length,
    kernel: report.kernel.length,
    vendored: report.vendored.length,
    dbBuilt: report.dbBuilt,
    scannedAt: report.scannedAt,
    scanner: report.scanner,
  }
}

const args = process.argv.slice(2)
const pretty = args.includes('--pretty')
const files = args.filter((arg) => arg !== '--pretty')

if (files.length === 0) {
  process.stderr.write('usage: node scripts/grade.mjs [--pretty] <vuln.json> [...]\n')
  process.exit(2)
}

let failed = false
for (const file of files) {
  let summary
  try {
    const report = parseVulnReport(JSON.parse(await readFile(file, 'utf8')))
    if (!report) throw new Error('not a grype vulnerability report')
    summary = { file, ...summarizeGrade(report) }
  } catch (error) {
    failed = true
    process.stderr.write(`grade: ${file}: ${error instanceof Error ? error.message : error}\n`)
    continue
  }
  process.stdout.write(`${JSON.stringify(summary, null, pretty ? 2 : 0)}\n`)
}

process.exit(failed ? 1 : 0)
