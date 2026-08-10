#!/usr/bin/env bash
# Rebuild-to-patch loop: find published kube images whose readiness grade a
# rebuild would improve, and dispatch the build workflows for them.
#
# Sibling of edgestack-image-builder's scripts/auto-remediate.sh — same chain
# (mirror re-scan keeps vuln.json current; scripts/grade.mjs, a vendored copy
# of the portal's formula, grades the actionable set; a non-empty `drivers`
# list means "a rebuild picks up these distro-published fixes"), but the
# sweep-and-map stage is this builder's own: tags here are
# v<semver>[-doca]-<arch> and the dispatch unit is (workflow, os,
# kube_version), exactly what scripts/pending-kube-builds.py dispatches for
# new upstream patches. This loop is its security twin: pending-kube-builds
# rebuilds because upstream moved, this rebuilds because the distro shipped a
# fix the image lacks. The rebuilt image republishes its tags and a fresh
# report, the next run sees empty drivers, and the loop stands down.
#
# Scope per (os, flavour, minor series): the NEWEST patch only. Older patches
# stay published for reproducibility but are not what operators deploy;
# rebuilding v1.34.9 when v1.34.10 exists would burn a runner on an image
# nobody consumes. -cilium tags never match the regex — that branch owns its
# own schedule (same rule as pending-kube-builds.py).
#
# Safety rails:
#   MAX_DISPATCH     dispatches per run; one dispatch builds BOTH arches
#   COOLDOWN_HOURS   per-combo; a rebuild that fails to clear its findings
#                    must not retry daily forever
#   busy hold        per workflow, snapshotted before dispatching (same
#                    pattern as auto-kube-release.yaml): a combo whose
#                    workflow already has runs queued/in progress is skipped,
#                    not queued behind them
#   DRY_RUN          report via issue only; flip the AUTO_REMEDIATE_DRY_RUN
#                    repo variable to "false" to go live
#
# Env:  DRY_RUN (true) · MAX_DISPATCH (4) · COOLDOWN_HOURS (72)
#       STATE_FILE      combo -> last-dispatch record, committed to this repo
#       GITHUB_TOKEN    actions:write + issues:write + contents:write; when
#                       empty the script forces DRY_RUN and prints the report
#       AUTO_REPO_LIST  override the repo sweep (testing)
#       EXCLUDE_KEY_REGEX  retire combos from the loop (key: os|flavour|vX.Y.Z)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=supply-chain.conf
. "$SCRIPT_DIR/supply-chain.conf"

DRY_RUN="${DRY_RUN:-true}"
MAX_DISPATCH="${MAX_DISPATCH:-4}"
COOLDOWN_HOURS="${COOLDOWN_HOURS:-72}"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/../.github/auto-remediate-state.json}"
REPO_SLUG="${GITHUB_REPOSITORY:-$BUILDER_REPO}"
TOKEN="${GITHUB_TOKEN:-}"
API="https://api.github.com/repos/${REPO_SLUG}"
DISPATCH_REF="${GITHUB_REF_NAME:-master}"
EXCLUDE_KEY_REGEX="${EXCLUDE_KEY_REGEX:-}"

# Image repository -> the `os` input the build workflows expect, and tag
# flavour -> owning workflow. Keep in sync with scripts/pending-kube-builds.py
# (IMAGE_REPOS / FLAVOURS there).
REPO_LIST=(${AUTO_REPO_LIST:-ubuntu-2404-kube:ubuntu rocky-9-uefi-kube:rocky})
flavour_workflow() { [[ "$1" == "-doca" ]] && echo "doca_image.yaml" || echo "main.yaml"; }

[[ -n "$TOKEN" ]] || DRY_RUN=true

log() { echo "[remediate] $*"; }
gh_api() {
  curl -sf -H "authorization: Bearer ${TOKEN}" \
    -H "accept: application/vnd.github+json" \
    -H "content-type: application/json" "$@"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/remediate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/reports"
: > "$WORK/meta.jsonl"

# ---- sweep quay: newest patch per (os, flavour, series), fetch reports ------
total=0 fetched=0
for entry in "${REPO_LIST[@]}"; do
  repo="${entry%%:*}"; os="${entry##*:}"
  tagfile="$WORK/${repo}.tags"; : > "$tagfile"
  page=1
  while :; do
    resp=$(curl -sf "https://${REGISTRY_HOST}/api/v1/repository/${REGISTRY_NAMESPACE}/${repo}/tag/?onlyActiveTags=true&limit=100&page=${page}") \
      || { log "quay listing failed for ${repo} — skipping repo"; break; }
    while IFS=$'\t' read -r tag digest; do
      [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-doca)?-(amd64|aarch64)$ ]] || continue
      printf '%s|%s|%s|%s\n' "${BASH_REMATCH[2]:-plain}" "${BASH_REMATCH[1]}" \
        "${BASH_REMATCH[3]}" "$digest" >> "$tagfile"
    done < <(echo "$resp" | jq -r '.tags[] | [.name, .manifest_digest] | @tsv')
    [[ "$(echo "$resp" | jq -r '.has_additional')" == "true" ]] || break
    page=$((page + 1))
  done
  [[ -s "$tagfile" ]] || continue

  # Newest patch per (flavour, series): versions sort correctly under sort -V,
  # and the newest is what operators actually deploy from each series.
  while IFS='|' read -r flavour version; do
    suffix=""; [[ "$flavour" == "-doca" ]] && suffix="-doca"
    [[ "$flavour" == "plain" ]] && flavour_arg="" || flavour_arg="$flavour"
    key="${os}|${flavour}|v${version}"
    if [[ -n "$EXCLUDE_KEY_REGEX" && "$key" =~ $EXCLUDE_KEY_REGEX ]]; then
      log "  ${repo}:v${version}${suffix} — retired combo (${key}), skipping"
      continue
    fi
    total=$((total + 1))
    while IFS='|' read -r _f _v arch digest; do
      tag="v${version}${suffix}-${arch}"
      out="$WORK/reports/${repo}__${tag}.vuln.json"
      # No mirrored report (stage failed, or the tag predates the pipeline)
      # means nothing to grade — skip, never guess.
      curl -sfL --compressed "${MIRROR_RAW}/${repo}/sha256-${digest#sha256:}.vuln.json" -o "$out" \
        || { rm -f "$out"; continue; }
      fetched=$((fetched + 1))
      jq -n --arg file "$out" --arg repo "$repo" --arg tag "$tag" --arg os "$os" \
        --arg workflow "$(flavour_workflow "$flavour_arg")" \
        --arg version "v${version}" --arg flavour "${flavour}" --arg key "$key" \
        '{kind: "meta", file: $file, repo: $repo, tag: $tag, os: $os,
          workflow: $workflow, kube_version: $version, flavour: $flavour, key: $key}' \
        >> "$WORK/meta.jsonl"
    done < <(grep "^${flavour}|${version}|" "$tagfile")
  done < <(cut -d'|' -f1,2 "$tagfile" | sort -u | awk -F'|' '{
      split($2, p, "."); series = $1 "|" p[1] "." p[2]
      if (!(series in best) || (p[3] + 0) > best[series]) { best[series] = p[3] + 0; line[series] = $0 }
    } END { for (s in line) print line[s] }')
done
log "newest-per-series combos: ${total}, arch reports fetched: ${fetched}"
[[ "$fetched" -gt 0 ]] || { log "nothing to grade"; exit 0; }

# ---- grade with the vendored portal formula ---------------------------------
# grade.mjs exits 1 when any single input fails to parse but still grades the
# rest; a missing-output check replaces the exit code as the failure signal.
node "$SCRIPT_DIR/grade.mjs" "$WORK"/reports/*.vuln.json > "$WORK/grades.jsonl" || true
[[ -s "$WORK/grades.jsonl" ]] || { log "ERROR: grading produced no output"; exit 1; }
log "graded $(wc -l < "$WORK/grades.jsonl" | tr -d ' ') report(s)"

# ---- fold arch reports into dispatch combos, worst first --------------------
# A combo (workflow, os, kube_version) is the dispatch unit — one dispatch
# rebuilds both architectures, so the amd64/aarch64 pair merges here.
# `drivers` non-empty is the whole trigger.
now=$(date -u +%s)
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
candidates=$(cat "$WORK/grades.jsonl" "$WORK/meta.jsonl" | jq -s \
  --slurpfile state "$STATE_FILE" --argjson now "$now" --argjson cool "$((COOLDOWN_HOURS * 3600))" '
  (map(select(.kind == "meta")) | INDEX(.file)) as $meta
  | map(select(.kind != "meta")
        | select((.drivers // []) | length > 0)
        | . + ($meta[.file] // {}) | select(.key))
  | group_by(.key)
  | map({key: .[0].key, os: .[0].os, workflow: .[0].workflow,
         kube_version: .[0].kube_version, flavour: .[0].flavour,
         tags: ([.[].tag] | sort), grade: ([.[].grade] | max),
         critical: ([.[].bySeverity.Critical] | add),
         high: ([.[].bySeverity.High] | add),
         cves: ([.[].drivers[].id] | unique),
         cooling: ((($state[0][.[0].key].last_dispatch // 0)) as $last | ($now - $last) < $cool)})
  | sort_by(.critical, .high) | reverse')

n_all=$(echo "$candidates" | jq 'length')
eligible=$(echo "$candidates" | jq --argjson max "$MAX_DISPATCH" '[.[] | select(.cooling | not)][:$max]')
n_eligible=$(echo "$eligible" | jq 'length')
log "combos needing a rebuild: ${n_all} (dispatching up to ${n_eligible})"

# ---- per-workflow busy hold, snapshotted before the loop --------------------
# Same reasoning as auto-kube-release.yaml: a build in flight has not
# republished its tags or report yet, so its combo still looks degraded; the
# snapshot also keeps our own dispatches from looking busy to their siblings.
busy=""
if [[ -n "$TOKEN" && "$n_eligible" -gt 0 && "$DRY_RUN" != "true" ]]; then
  for workflow in $(echo "$eligible" | jq -r '[.[].workflow] | unique | .[]'); do
    for state in queued in_progress; do
      count=$(gh_api "$API/actions/workflows/${workflow}/runs?status=${state}&per_page=1" \
        | jq '.total_count' 2>/dev/null) || count=1   # unreadable = busy
      if [[ "${count:-1}" != "0" ]]; then
        log "hold ${workflow}: run(s) ${state}"
        busy="${busy} ${workflow}"
        break
      fi
    done
  done
fi

# ---- dispatch ---------------------------------------------------------------
dispatched=0
if [[ "$DRY_RUN" != "true" ]]; then
  while IFS= read -r combo; do
    key=$(echo "$combo" | jq -r '.key')
    workflow=$(echo "$combo" | jq -r '.workflow')
    case " ${busy} " in *" ${workflow} "*)
      log "skip ${key}: ${workflow} already building, retry next run"
      continue ;;
    esac
    # strict/force toggles are declared required by the build workflows, so
    # they are sent explicitly at their documented defaults (same as
    # auto-kube-release.yaml).
    payload=$(echo "$combo" | jq --arg ref "$DISPATCH_REF" '{ref: $ref,
      inputs: {os: .os, kube_version: .kube_version,
               sbom_strict: "true", sbom_force: "false",
               vuln_strict: "true", vuln_force: "false",
               provenance_strict: "true", provenance_force: "false"}}')
    if gh_api -X POST "$API/actions/workflows/${workflow}/dispatches" -d "$payload" > /dev/null; then
      dispatched=$((dispatched + 1))
      jq --arg k "$key" --argjson now "$now" --argjson c "$combo" \
        '.[$k] = {last_dispatch: $now, grade: $c.grade, tags: $c.tags, cves: $c.cves}' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
      log "dispatched ${key} ($(echo "$combo" | jq -r '.cves | join(", ")'))"
    else
      log "ERROR: dispatch failed for ${key} — skipping, state untouched"
    fi
  done < <(echo "$eligible" | jq -c '.[]')
fi

# ---- report: job summary + standing issue -----------------------------------
mode="DRY RUN — no builds dispatched"
[[ -z "$TOKEN" ]] && mode="DRY RUN (no token) — no builds dispatched"
[[ "$dispatched" -gt 0 ]] && mode="LIVE — dispatched ${dispatched} build(s)"

rows=$(echo "$candidates" | jq -r '.[] |
  "| \(.os) | \(.kube_version)\(if .flavour == "-doca" then " doca" else "" end) | \(.grade) | \(.critical) | \(.high) | \(.cves | join(", ")) | \(if .cooling then "cooling down" else "ready" end) |"')

body=$(cat <<EOF
**${mode}** — $(date -u +%FT%TZ), formula: \`scripts/grade.mjs\` (portal formula v1, vendored)

Kube images whose readiness grade a rebuild would improve — the newest patch
of each published series only. The trigger is a non-empty \`drivers\` list:
actionable Critical/High findings whose fix the distribution really
publishes, so the rebuild is guaranteed to clear them.

| OS | version | grade | Crit | High | driver CVEs | status |
|---|---|---|---|---|---|---|
${rows:-| _none_ | | | | | | |}

- One dispatch builds **both architectures** of a combo.
- Cap ${MAX_DISPATCH}/run, cooldown ${COOLDOWN_HOURS}h per combo; a combo whose
  workflow is already building is held for the next run.
- Go live / pause: set repository variable \`AUTO_REMEDIATE_DRY_RUN\` to
  \`false\` / \`true\`. State: \`.github/auto-remediate-state.json\`.
EOF
)

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$body" >> "$GITHUB_STEP_SUMMARY"; fi

if [[ -z "$TOKEN" ]]; then
  echo "$body"
elif [[ "$n_all" -gt 0 ]]; then
  # One standing issue as the dashboard: update it if open, else create it.
  gh_api -X POST "$API/labels" \
    -d '{"name":"auto-remediate","color":"d93f0b","description":"Images the remediation loop wants to rebuild"}' \
    > /dev/null 2>&1 || true
  num=$(gh_api "$API/issues?state=open&labels=auto-remediate&per_page=1" | jq -r '.[0].number // empty' || true)
  title="Auto-remediation: ${n_all} kube image combo(s) need a rebuild"
  if [[ -n "$num" ]]; then
    gh_api -X PATCH "$API/issues/${num}" \
      -d "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b}')" > /dev/null \
      && log "updated issue #${num}"
  else
    gh_api -X POST "$API/issues" \
      -d "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b, labels: ["auto-remediate"]}')" > /dev/null \
      && log "opened tracking issue"
  fi
else
  # Drained: close the dashboard issue so an open issue always means work left.
  num=$(gh_api "$API/issues?state=open&labels=auto-remediate&per_page=1" | jq -r '.[0].number // empty' || true)
  if [[ -n "$num" ]]; then
    gh_api -X PATCH "$API/issues/${num}" \
      -d "$(jq -n --arg b "$body" '{state: "closed", body: $b}')" > /dev/null \
      && log "all clear — closed issue #${num}"
  fi
fi

# ---- persist state ----------------------------------------------------------
if [[ "$dispatched" -gt 0 ]]; then
  root=$(cd "$SCRIPT_DIR/.." && pwd)
  git -C "$root" config user.name "$MIRROR_GIT_NAME"
  git -C "$root" config user.email "$MIRROR_GIT_EMAIL"
  git -C "$root" add "$STATE_FILE"
  git -C "$root" commit -q -m "auto-remediate: dispatch $(echo "$eligible" | jq -r '[.[].key] | join(", ")')"
  for attempt in 1 2 3; do
    git -C "$root" push -q origin HEAD && { log "state committed"; break; }
    log "state push failed (attempt ${attempt}/3) — rebasing"
    git -C "$root" pull -q --rebase origin "$DISPATCH_REF"
  done
fi

log "done: ${mode}"
