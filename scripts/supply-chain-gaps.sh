#!/usr/bin/env bash
# Find recent pushes that are missing a supply-chain stage and backfill them.
#
# A build job publishes an image's SBOM, vulnerability report and signature
# sidecar right after its push. A job cut off after the push (the job time
# limit, a cancelled run) or one whose publishing stage failed leaves the image
# on quay.io without them, and re-running the job would build the image again.
# This sweep compares quay.io with the mirror instead: every per-arch tag of
# this builder's repositories (IMAGE_REPOS and IMAGE_TAG_RE in
# supply-chain.conf) pushed within LOOKBACK_HOURS, and at least GRACE_MINUTES
# ago (a live build is still publishing), whose digest lacks any of
# <repo>/sha256-<hex>.{spdx,vuln,signature}.json in the mirror, goes to
# backfill-supply-chain.yaml in one dispatch.
#
# Each image is dispatched once: a backfill run is named after its images, and
# an image named by a backfill run in the window is left for a person if it
# still lacks a stage (a stage that fails twice is not transient). Nothing is
# dispatched while a backfill is queued or running.
#
# Older images without a stage (built before the stages existed) are left
# alone: dispatch backfill-supply-chain.yaml for them by hand.
#
# Env:  DRY_RUN (true)         list what would be backfilled, dispatch nothing
#       LOOKBACK_HOURS (72)    tags pushed within this window are checked
#       GRACE_MINUTES (180)    tags pushed more recently are left to their build
#       GH_TOKEN               token with actions: write on this repository
#       GH_REPO                owner/repo
#
# Plain curl + jq: the self-hosted runners do not carry the gh CLI. Shared
# verbatim between the image builders, like the pipeline scripts.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=supply-chain.conf
. "$SCRIPT_DIR/supply-chain.conf"

DRY_RUN="${DRY_RUN:-true}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-72}"
GRACE_MINUTES="${GRACE_MINUTES:-180}"
BACKFILL_WORKFLOW="backfill-supply-chain.yaml"
STAGES=(spdx vuln signature)

log() { echo "[gaps] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is not set"
[[ -n "${GH_REPO:-}" ]] || die "GH_REPO is not set (owner/repo)"
[[ "$LOOKBACK_HOURS" =~ ^[0-9]+$ ]] || die "LOOKBACK_HOURS must be an integer: ${LOOKBACK_HOURS}"
[[ "$GRACE_MINUTES" =~ ^[0-9]+$ ]] || die "GRACE_MINUTES must be an integer: ${GRACE_MINUTES}"
API="https://api.github.com/repos/${GH_REPO}"

gh_api() {
  curl -sf -H "authorization: Bearer ${GH_TOKEN}" \
    -H "accept: application/vnd.github+json" \
    -H "content-type: application/json" "$@"
}

now=$(date -u +%s)
from=$((now - LOOKBACK_HOURS * 3600))
to=$((now - GRACE_MINUTES * 60))
# GNU date on the runners; the BSD form keeps the script runnable on a Mac.
since=$(date -u -d "@${from}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$from" +%Y-%m-%dT%H:%M:%SZ)

log "checking tags pushed ${LOOKBACK_HOURS} h to ${GRACE_MINUTES} min ago (dry run ${DRY_RUN})"

# The backfill runs of the window: none may be under way, and the images they
# named are not dispatched again.
runs=$(gh_api -G "$API/actions/workflows/${BACKFILL_WORKFLOW}/runs" \
    --data-urlencode "created=>=${since}" --data-urlencode "per_page=100") \
  || die "listing runs of ${BACKFILL_WORKFLOW} failed"
if jq -e '[.workflow_runs[] | select(.status != "completed")] | length > 0' <<< "$runs" >/dev/null; then
  log "a backfill is queued or running — nothing dispatched this round"
  exit 0
fi
named=$(jq -r '.workflow_runs[].display_title' <<< "$runs" | tr ' ' '\n')

images=()
for repo in "${IMAGE_REPOS[@]}"; do
  page=1
  while :; do
    if ! data=$(curl -sf --retry 3 --retry-delay 5 \
        "https://${REGISTRY_HOST}/api/v1/repository/${REGISTRY_NAMESPACE}/${repo}/tag/?onlyActiveTags=true&limit=100&page=${page}"); then
      log "WARNING: quay.io listing of ${repo} failed — skipping it this round"
      break
    fi
    while read -r tag digest; do
      [[ -n "$tag" ]] || continue
      missing=()
      for stage in "${STAGES[@]}"; do
        curl -sfI -o /dev/null "${MIRROR_RAW}/${repo}/sha256-${digest#sha256:}.${stage}.json" \
          || missing+=("$stage")
      done
      [[ ${#missing[@]} -gt 0 ]] || continue
      if grep -qxF "${repo}:${tag}" <<< "$named"; then
        log "${repo}:${tag} (${digest:7:12}) still lacks ${missing[*]} after a backfill — leaving it for a person"
        continue
      fi
      log "${repo}:${tag} (${digest:7:12}) lacks ${missing[*]}"
      images+=("${repo}:${tag}")
    done < <(jq -r --arg re "$IMAGE_TAG_RE" --argjson from "$from" --argjson to "$to" \
      '.tags[] | select((.name | test($re)) and .start_ts >= $from and .start_ts <= $to)
       | "\(.name) \(.manifest_digest)"' <<< "$data")
    [[ "$(jq -r '.has_additional' <<< "$data")" == "true" ]] || break
    page=$((page + 1))
    [[ $page -le 20 ]] || break   # sanity cap
  done
done

if [[ ${#images[@]} -eq 0 ]]; then
  log "no recent push lacks a supply-chain stage"
  exit 0
fi
if [[ "$DRY_RUN" == "true" ]]; then
  log "would dispatch ${BACKFILL_WORKFLOW} for ${#images[@]} image(s) (dry run)"
  exit 0
fi

ref=$(gh_api "$API" | jq -r '.default_branch') || die "reading the default branch failed"
jq -nc --arg ref "$ref" --arg images "${images[*]}" '{ref: $ref, inputs: {images: $images, force: "false"}}' \
  | gh_api -X POST "$API/actions/workflows/${BACKFILL_WORKFLOW}/dispatches" -d @- -o /dev/null \
  || die "dispatching ${BACKFILL_WORKFLOW} failed"
log "dispatched ${BACKFILL_WORKFLOW} for ${#images[@]} image(s): ${images[*]}"
