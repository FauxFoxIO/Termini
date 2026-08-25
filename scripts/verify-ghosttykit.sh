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

# Termini relies on Ghostty's public C ABI. Keep this list synchronized with
# the direct C API calls in Sources/Termini so a stale or unpatched framework
# cannot be published successfully.
required_apis=(
  ghostty_init
  ghostty_info
  ghostty_config_new
  ghostty_config_free
  ghostty_config_clone
  ghostty_config_load_file
  ghostty_config_load_default_files
  ghostty_config_finalize
  ghostty_config_set_font_size
  ghostty_config_set_font_family
  ghostty_app_new
  ghostty_app_free
  ghostty_app_tick
  ghostty_app_set_focus
  ghostty_app_keyboard_changed
  ghostty_surface_config_new
  ghostty_surface_new
  ghostty_surface_free
  ghostty_surface_update_config
  ghostty_surface_refresh
  ghostty_surface_draw
  ghostty_surface_set_content_scale
  ghostty_surface_set_focus
  ghostty_surface_set_occlusion
  ghostty_surface_set_size
  ghostty_surface_size
  ghostty_surface_set_color_scheme
  ghostty_surface_key_translation_mods
  ghostty_surface_key
  ghostty_surface_text
  ghostty_surface_process_output
  ghostty_surface_mouse_button
  ghostty_surface_mouse_pos
  ghostty_surface_mouse_scroll
  ghostty_surface_binding_action
  ghostty_surface_complete_clipboard_request
  ghostty_surface_read_text
  ghostty_surface_free_text
)

for header in "${XCFRAMEWORK_PATH}"/*/Headers/ghostty.h; do
  [[ -f "${header}" ]] || continue
  for api in "${required_apis[@]}"; do
    if ! /usr/bin/grep -Eq "GHOSTTY_API.*${api}[[:space:]]*\\(" "${header}"; then
      echo "error: $(dirname "${header}") is missing required declaration ${api}" >&2
      exit 1
    fi
  done
done

for library in "${XCFRAMEWORK_PATH}"/*/*.a; do
  [[ -f "${library}" ]] || continue
  exported_symbols="$(nm -gU "${library}")"
  for api in "${required_apis[@]}"; do
    if ! /usr/bin/grep -Eq "[[:space:]]_${api}$" <<< "${exported_symbols}"; then
      echo "error: ${library} is missing required symbol ${api}" >&2
      exit 1
    fi
  done
done

echo "GhosttyKit headers and libraries expose all Termini-required APIs"
