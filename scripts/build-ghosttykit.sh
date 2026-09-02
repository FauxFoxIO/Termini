#!/usr/bin/env bash
# Build GhosttyKit.xcframework from a local Ghostty checkout and install it
# into Termini's vendored path. The source must emit macOS, iOS (including
# universal Simulator), and visionOS device/Simulator slices.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="${GHOSTTY_DIR:-${REPO_ROOT}/vendor/ghostty}"
GHOSTTY_REPO="${GHOSTTY_REPO:-git@github.com:FauxFoxIO/ghostty.git}"
GHOSTTY_REF="${GHOSTTY_REF:-d71bcd105abafd03a5da4cb389219e4ecae01b07}"
GHOSTTY_OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"
GHOSTTY_PATCH_DIR="${GHOSTTY_PATCH_DIR:-${REPO_ROOT}/patches/ghostty/0.1.6-zig016}"
GHOSTTYKIT_INSTALL_DIR="${GHOSTTYKIT_INSTALL_DIR:-${REPO_ROOT}/vendor/ghostty/macos}"
GHOSTTYKIT_METADATA_PATH="${GHOSTTYKIT_METADATA_PATH:-${REPO_ROOT}/vendor/ghosttykit-metadata.json}"
ZIG="${ZIG:-zig}"
SHOULD_FETCH=0

usage() {
  cat <<EOF
Usage: $0 [--ghostty-dir PATH] [--ref REF] [--fetch] [--optimize MODE]

Options:
  --ghostty-dir PATH   Ghostty checkout to build from. Default: ${GHOSTTY_DIR}
  --ref REF            Git ref to check out before building.
  --fetch              Fetch origin before checking out REF.
  --optimize MODE      Zig optimize mode. Default: ${GHOSTTY_OPTIMIZE}
  --patch-dir PATH     Patches for the pinned Ghostty source. Default: ${GHOSTTY_PATCH_DIR}

Env:
  GHOSTTY_DIR
  GHOSTTY_REPO
  GHOSTTY_REF
  GHOSTTY_OPTIMIZE
  GHOSTTY_PATCH_DIR
  GHOSTTYKIT_INSTALL_DIR   Directory receiving GhosttyKit.xcframework (default: ${GHOSTTYKIT_INSTALL_DIR})
  GHOSTTYKIT_METADATA_PATH Metadata output path (default: ${GHOSTTYKIT_METADATA_PATH})
  ZIG                 Zig 0.16 executable (default: ${ZIG})
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing dependency '$1'" >&2
    exit 1
  fi
}

apply_patches() {
  if [[ ! -d "${GHOSTTY_PATCH_DIR}" ]]; then
    echo "error: Ghostty patch directory does not exist: ${GHOSTTY_PATCH_DIR}" >&2
    exit 1
  fi

  local patches=()
  local patch
  while IFS= read -r patch; do
    patches+=("${patch}")
  done < <(find "${GHOSTTY_PATCH_DIR}" -type f -name '*.patch' -print | LC_ALL=C sort)

  if [[ "${#patches[@]}" -eq 0 ]]; then
    echo "error: no Ghostty patches found in ${GHOSTTY_PATCH_DIR}" >&2
    exit 1
  fi

  for patch in "${patches[@]}"; do
    if git -C "${GHOSTTY_DIR}" apply --unidiff-zero --reverse --check "${patch}" >/dev/null 2>&1; then
      echo "Patch already applied: $(basename "${patch}")"
      continue
    fi
    if ! git -C "${GHOSTTY_DIR}" apply --unidiff-zero --check "${patch}"; then
      echo "error: patch does not apply cleanly: ${patch}" >&2
      exit 1
    fi
    git -C "${GHOSTTY_DIR}" apply --unidiff-zero "${patch}"
    echo "Applied patch: $(basename "${patch}")"
  done
}

ensure_checkout() {
  if [[ -d "${GHOSTTY_DIR}/.git" || -f "${GHOSTTY_DIR}/.git" ]]; then
    return
  fi

  mkdir -p "$(dirname "${GHOSTTY_DIR}")"
  git clone --filter=blob:none "${GHOSTTY_REPO}" "${GHOSTTY_DIR}"
}

update_checkout() {
  if [[ -z "${GHOSTTY_REF}" ]]; then
    return
  fi

  if [[ -n "$(git -C "${GHOSTTY_DIR}" status --porcelain)" ]]; then
    echo "error: ${GHOSTTY_DIR} has uncommitted changes; refusing to switch refs" >&2
    exit 1
  fi

  if [[ "${SHOULD_FETCH}" == "1" ]]; then
    git -C "${GHOSTTY_DIR}" fetch --tags origin
  fi

  git -C "${GHOSTTY_DIR}" checkout "${GHOSTTY_REF}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ghostty-dir)
      GHOSTTY_DIR="$2"
      shift 2
      ;;
    --ref)
      GHOSTTY_REF="$2"
      shift 2
      ;;
    --fetch)
      SHOULD_FETCH=1
      shift
      ;;
    --optimize)
      GHOSTTY_OPTIMIZE="$2"
      shift 2
      ;;
    --patch-dir)
      GHOSTTY_PATCH_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd git
if [[ "${ZIG}" == */* ]]; then
  [[ -x "${ZIG}" ]] || { echo "error: Zig executable is not runnable: ${ZIG}" >&2; exit 1; }
else
  require_cmd "${ZIG}"
fi

ensure_checkout
update_checkout
apply_patches

(
  cd "${GHOSTTY_DIR}"
  # Embedded libraries must not install a process-wide crash handler; the host owns that policy.
  "${ZIG}" build \
    -Dapp-runtime=none \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Demit-exe=false \
    -Doptimize="${GHOSTTY_OPTIMIZE}" \
    -Dxcframework-target=universal
)

GHOSTTYKIT_INSTALL_DIR="${GHOSTTYKIT_INSTALL_DIR}" \
GHOSTTYKIT_METADATA_PATH="${GHOSTTYKIT_METADATA_PATH}" \
  "${REPO_ROOT}/scripts/install-ghosttykit.sh" "${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
GHOSTTYKIT_INSTALL_DIR="${GHOSTTYKIT_INSTALL_DIR}" \
  "${REPO_ROOT}/scripts/verify-ghosttykit.sh" \
  "${GHOSTTYKIT_INSTALL_DIR}/GhosttyKit.xcframework"

echo "Built GhosttyKit from $(git -C "${GHOSTTY_DIR}" rev-parse --short HEAD)"
