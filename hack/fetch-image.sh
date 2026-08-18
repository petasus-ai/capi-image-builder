#!/usr/bin/env bash

# Pre-fetch the cloud image referenced by a Packer var file and emit a var file
# that points Packer at the verified local copy.
#
# repo.almalinux.org and dl.rockylinux.org sit behind a caching proxy that
# intermittently truncates large responses mid-transfer (observed as a hard cut
# at exactly 80,000,000 bytes). Over HTTP/2 that surfaces as "stream error:
# PROTOCOL_ERROR"; over HTTP/1.1 it surfaces as a short read that Packer only
# notices as a checksum mismatch. Packer's downloader can neither resume nor
# retry, so a truncated transfer always fails the build. curl can resume, so do
# the download here and hand Packer a file it only has to checksum.
#
# The resume loop is implemented here rather than with curl's --retry-all-errors
# because the build runners ship curl 7.61, and that option only landed in
# 7.71. Every option used below predates curl 7.33.

set -o errexit
set -o nounset
set -o pipefail

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <packer-var-file> [override-var-file]

  packer-var-file    e.g. packer/qemu/qemu-alma-9-aarch64.json
  override-var-file  where to write the Packer var file pointing at the local
                     image (default: stdout)

Environment:
  IMAGE_CACHE_DIR    where images are kept (default: \$HOME/.cache/edgestack-images)
  FETCH_ATTEMPTS     clean re-download attempts after a corrupt result (default: 3)
  FETCH_RESUMES      resumes allowed within one attempt (default: 40)
  RESOLVE_ONLY       set to 1 to print the resolved checksum and exit
EOF
  exit 1
}

[ $# -ge 1 ] || usage

VAR_FILE="$1"
OVERRIDE_FILE="${2:-}"
CACHE_DIR="${IMAGE_CACHE_DIR:-${HOME}/.cache/edgestack-images}"
ATTEMPTS="${FETCH_ATTEMPTS:-3}"
RESUMES="${FETCH_RESUMES:-40}"

[ -f "$VAR_FILE" ] || { echo "no such var file: $VAR_FILE" >&2; exit 1; }

ISO_URL="$(jq -r '.iso_url // empty' "$VAR_FILE")"
ISO_CHECKSUM="$(jq -r '.iso_checksum // empty' "$VAR_FILE")"
ISO_CHECKSUM_TYPE="$(jq -r '.iso_checksum_type // empty' "$VAR_FILE")"

[ -n "$ISO_URL" ] || { echo "$VAR_FILE has no iso_url" >&2; exit 1; }
[ -n "$ISO_CHECKSUM" ] || { echo "$VAR_FILE has no iso_checksum" >&2; exit 1; }

IMAGE_NAME="$(basename "${ISO_URL%%\?*}")"

# Logged so that a future incompatibility is diagnosable straight from the build
# output rather than from a bare "option is unknown".
echo "==> $(curl --version | head -n 1)"

# Print the hex digest of a file, preferring GNU coreutils and falling back to
# the shasum(1) found on macOS.
digest() {
  local algo="$1" file="$2"
  if command -v "${algo}sum" >/dev/null 2>&1; then
    "${algo}sum" "$file" | awk '{print $1}'
  else
    shasum -a "${algo#sha}" "$file" | awk '{print $1}'
  fi
}

# wc(1) rather than stat(1): the GNU and BSD stat flags are incompatible.
file_size() {
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

# Pull the digest for $IMAGE_NAME out of a checksum manifest. Handles both the
# coreutils layout used by AlmaLinux and Ubuntu ("<hash>  name", "<hash> *name")
# and the BSD layout used by Rocky ("SHA256 (name) = <hash>").
parse_checksum_file() {
  local file="$1" hash

  hash="$(awk -v want="$IMAGE_NAME" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == want) { print $1; exit }
    }' "$file")"

  if [ -z "$hash" ]; then
    hash="$(awk -v want="($IMAGE_NAME)" '
      $2 == want && $3 == "=" { print $4; exit }' "$file")"
  fi

  printf '%s' "$hash"
}

if [ "$ISO_CHECKSUM_TYPE" = "file" ]; then
  echo "==> Resolving checksum for ${IMAGE_NAME} from ${ISO_CHECKSUM}"
  CHECKSUM_FILE="$(mktemp)"
  trap 'rm -f "$CHECKSUM_FILE"' EXIT
  curl --fail --silent --show-error --location --http1.1 \
    --connect-timeout 30 --max-time 120 --retry 5 --retry-delay 3 \
    --output "$CHECKSUM_FILE" "$ISO_CHECKSUM"

  EXPECTED="$(parse_checksum_file "$CHECKSUM_FILE")"
  if [ -z "$EXPECTED" ]; then
    echo "no entry for ${IMAGE_NAME} in ${ISO_CHECKSUM}" >&2
    exit 1
  fi

  case "${#EXPECTED}" in
    64)  ALGO="sha256" ;;
    128) ALGO="sha512" ;;
    *)   echo "unrecognised digest length ${#EXPECTED} for ${IMAGE_NAME}" >&2; exit 1 ;;
  esac
else
  EXPECTED="$ISO_CHECKSUM"
  ALGO="$ISO_CHECKSUM_TYPE"
fi

echo "==> Expecting ${ALGO}:${EXPECTED}"
if [ "${RESOLVE_ONLY:-}" = "1" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR"
DEST="${CACHE_DIR}/${IMAGE_NAME}"

# The cache directory is shared by every runner on the host, and nothing used
# to stop two jobs from fetching the same image at once: both curls appended
# into one file via --continue-at, and a failed job's rm -f yanked the file out
# from under the other's in-flight download. Either way the corruption only
# surfaced later, as a checksum mismatch (or as a "Received N bytes" whose N is
# really the size of the OTHER job's fresh partial file). Serialize on a
# per-image lock held for the rest of the script; a job that had to wait
# re-checks the cache below and normally finds the winner's verified image.
# flock(1) is util-linux, so it is missing on macOS; there this degrades to the
# old unlocked behaviour, which a laptop running one build at a time never hits.
if command -v flock >/dev/null 2>&1; then
  exec 9>"${DEST}.lock"
  if ! flock -n 9; then
    echo "==> Another job is fetching ${IMAGE_NAME}; waiting for its lock"
    flock 9
  fi
fi

verified() {
  [ -f "$DEST" ] || return 1
  [ "$(digest "$ALGO" "$DEST")" = "$EXPECTED" ]
}

# Resume until curl reports a complete transfer. The proxy cuts most responses
# short, so one invocation rarely carries the whole image; each round picks up
# from the bytes already on disk. Give up once a round adds nothing, which means
# the transfer is stuck rather than merely slow.
download() {
  local round=1 stalls=0 rc before size

  while [ "$round" -le "$RESUMES" ]; do
    before="$(file_size "$DEST")"

    rc=0
    curl --fail --location --http1.1 --silent --show-error \
      --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
      --continue-at - --output "$DEST" "$ISO_URL" || rc=$?

    size="$(file_size "$DEST")"

    if [ "$rc" -eq 0 ]; then
      echo "==> Received ${size} bytes"
      return 0
    fi

    case "$rc" in
      # 22: HTTP error, which includes the 416 returned when the local file is
      # already as long as the remote one. 33/36: the server refused the range
      # request, or curl rejected the resume offset. None can be resumed past.
      22|33|36)
        echo "==> curl exit ${rc} at ${size} bytes: transfer cannot be resumed"
        return 1
        ;;
    esac

    if [ "$size" -gt "$before" ]; then
      stalls=0
      echo "==> Truncated at ${size} bytes (curl exit ${rc}), resuming"
    else
      stalls=$((stalls + 1))
      echo "==> No progress at ${size} bytes (curl exit ${rc}), retry ${stalls}/3"
      if [ "$stalls" -ge 3 ]; then
        return 1
      fi
      sleep 5
    fi

    round=$((round + 1))
  done

  echo "==> Still incomplete after ${RESUMES} resumes"
  return 1
}

if verified; then
  echo "==> Using cached ${DEST}"
else
  attempt=1
  while [ "$attempt" -le "$ATTEMPTS" ]; do
    echo "==> Downloading ${ISO_URL} (attempt ${attempt}/${ATTEMPTS})"
    if download && verified; then
      break
    fi

    # Whatever is on disk cannot be repaired by resuming: either the transfer is
    # unresumable, or the bytes came from a stale "-latest" image and every
    # resume extends a file that can never match. Start the next attempt clean.
    echo "==> Discarding ${DEST}"
    rm -f "$DEST"
    attempt=$((attempt + 1))
  done
fi

if ! verified; then
  echo "failed to fetch a valid ${IMAGE_NAME} after ${ATTEMPTS} attempts" >&2
  exit 1
fi

echo "==> Verified ${DEST}"

OVERRIDE_JSON="$(jq -n \
  --arg url "$DEST" \
  --arg checksum "$EXPECTED" \
  --arg type "$ALGO" \
  '{iso_url: $url, iso_checksum: $checksum, iso_checksum_type: $type}')"

if [ -n "$OVERRIDE_FILE" ]; then
  printf '%s\n' "$OVERRIDE_JSON" > "$OVERRIDE_FILE"
  echo "==> Wrote ${OVERRIDE_FILE}"
else
  printf '%s\n' "$OVERRIDE_JSON"
fi
