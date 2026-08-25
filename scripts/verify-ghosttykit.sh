#!/usr/bin/env bash
# Verify that GhosttyKit can link Apple mobile and immersive consumers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK_PATH="${1:-${REPO_ROOT}/vendor/ghostty/macos/GhosttyKit.xcframework}"

if [[ ! -d "${XCFRAMEWORK_PATH}" ]]; then
  echo "error: '${XCFRAMEWORK_PATH}' does not exist or is not a directory" >&2
  exit 1
fi

SIMULATOR_DIR="$(find "${XCFRAMEWORK_PATH}" -mindepth 1 -maxdepth 1 -type d -name 'ios-*-simulator' -print -quit)"
if [[ -z "${SIMULATOR_DIR}" ]]; then
  echo "error: GhosttyKit has no iOS Simulator slice" >&2
  exit 1
fi

SIMULATOR_LIBRARY="${SIMULATOR_DIR}/libghostty-fat.a"
if [[ ! -f "${SIMULATOR_LIBRARY}" ]]; then
  echo "error: iOS Simulator slice is missing normalized library ${SIMULATOR_LIBRARY}" >&2
  exit 1
fi

ARCHITECTURES="$(lipo -archs "${SIMULATOR_LIBRARY}")"
for required in arm64 x86_64; do
  if [[ " ${ARCHITECTURES} " != *" ${required} "* ]]; then
    echo "error: iOS Simulator slice is missing ${required} (found: ${ARCHITECTURES})" >&2
    exit 1
  fi
done

echo "GhosttyKit iOS Simulator architectures: ${ARCHITECTURES}"

verify_slice() {
  local platform="$1"
  local pattern="$2"
  local required_arch="$3"
  local slice_dir
  slice_dir="$(find "${XCFRAMEWORK_PATH}" -mindepth 1 -maxdepth 1 -type d -name "${pattern}" -print -quit)"
  if [[ -z "${slice_dir}" ]]; then
    echo "error: GhosttyKit has no ${platform} slice" >&2
    exit 1
  fi
  local library="${slice_dir}/libghostty-fat.a"
  [[ -f "${library}" ]] || library="${slice_dir}/libghostty.a"
  [[ -f "${library}" ]] || library="${slice_dir}/libghostty-internal.a"
  if [[ ! -f "${library}" ]]; then
    echo "error: ${platform} slice is missing normalized library" >&2
    exit 1
  fi
  local architectures
  architectures="$(lipo -archs "${library}")"
  if [[ " ${architectures} " != *" ${required_arch} "* ]]; then
    echo "error: ${platform} slice is missing ${required_arch} (found: ${architectures})" >&2
    exit 1
  fi
  echo "GhosttyKit ${platform} architectures: ${architectures}"
}

verify_slice "visionOS device" 'xros-arm64' arm64
verify_slice "visionOS Simulator" 'xros-*-simulator' arm64
