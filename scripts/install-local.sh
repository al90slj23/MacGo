#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the existing bundle identity and preferences during the product rename.
macgo_expected_id="local.mactoolbox.app"
macgo_source="$PWD/dist/Mac Go.app"
macgo_install_dir="$HOME/Applications"
macgo_destination="$macgo_install_dir/Mac Go.app"
macgo_legacy="$macgo_install_dir/Mac 工具箱.app"
macgo_registrar="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[[ "$(id -u)" != 0 ]] || {
    printf 'Install as the current user without sudo.\n' >&2; exit 1;
}
[[ "$macgo_destination" == "$HOME/Applications/Mac Go.app" &&
   "$macgo_legacy" == "$HOME/Applications/Mac 工具箱.app" ]] || {
    printf 'Refusing unexpected installation destination.\n' >&2; exit 1;
}
[[ ! -L "$macgo_install_dir" ]] || {
    printf 'Refusing a symlinked Applications directory: %s\n' "$macgo_install_dir" >&2; exit 1;
}

require_macgo_bundle() {
    local candidate="$1"
    [[ -d "$candidate" && ! -L "$candidate" ]] || {
        printf 'Refusing unexpected app path: %s\n' "$candidate" >&2; return 1;
    }
    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")"
    [[ "$bundle_id" == "$macgo_expected_id" ]] || {
        printf 'Refusing unrelated app at: %s\n' "$candidate" >&2; return 1;
    }
}

require_macgo_bundle "$macgo_source"
codesign --verify --deep --strict "$macgo_source"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$macgo_source/Contents/Info.plist")" == MacGo &&
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$macgo_source/Contents/Info.plist")" == 'Mac Go' &&
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$macgo_source/Contents/Info.plist")" == 'Mac Go' ]] || {
    printf 'Refusing an app with an unexpected product name or executable.\n' >&2; exit 1;
}
[[ -x "$macgo_registrar" ]] || {
    printf 'Launch Services registration tool is unavailable.\n' >&2; exit 1;
}
for macgo_candidate in "$macgo_destination" "$macgo_legacy"; do
    if [[ -e "$macgo_candidate" || -L "$macgo_candidate" ]]; then
        require_macgo_bundle "$macgo_candidate"
    fi
done

# Never stop a running app or replace the files behind its current permissions.
require_no_running_app() {
local macgo_process macgo_process_status
for macgo_process in MacGo MacToolbox; do
    macgo_process_status=0
    pgrep -x "$macgo_process" >/dev/null 2>&1 || macgo_process_status=$?
    if [[ "$macgo_process_status" == 0 ]]; then
        printf 'Quit every Mac Go / Mac 工具箱 instance before installing (%s is running).\n' "$macgo_process" >&2
        exit 1
    elif [[ "$macgo_process_status" != 1 ]]; then
        printf 'Unable to verify whether %s is running; installation stopped.\n' "$macgo_process" >&2
        exit 1
    fi
done
}
require_no_running_app

mkdir -p "$macgo_install_dir"
macgo_lock="$macgo_install_dir/.macgo-install.lock"
mkdir "$macgo_lock" 2>/dev/null || {
    printf 'Another installation may be active; installation lock retained at: %s\n' "$macgo_lock" >&2
    exit 1
}
macgo_stage=""
macgo_previous=""
macgo_previous_legacy=""
macgo_published=0
macgo_registration_attempted=0
macgo_committed=0

# The two app bundles and all recovery artifacts stay on the same filesystem.
# Refuse an existing destination; never knowingly move into another app bundle.
move_to_empty_path() {
    local source="$1" destination="$2"
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        printf 'Refusing to overwrite a path created during installation: %s\n' "$destination" >&2
        return 1
    }
    /bin/mv "$source" "$destination"
}

rollback_install() {
    local failed=0
    if [[ "$macgo_published" == 1 ]]; then
        if require_macgo_bundle "$macgo_destination"; then
            move_to_empty_path "$macgo_destination" "$macgo_stage/failed-new.app" || failed=1
        else
            printf 'The published path changed; retaining previous apps for manual recovery.\n' >&2
            failed=1
        fi
        if [[ "$macgo_registration_attempted" == 1 ]]; then
            "$macgo_registrar" -u "$macgo_destination" || failed=1
        fi
    fi
    if [[ -n "$macgo_previous" && -d "$macgo_previous" ]]; then
        if move_to_empty_path "$macgo_previous" "$macgo_destination"; then
            "$macgo_registrar" -f "$macgo_destination" || failed=1
        else failed=1; fi
    fi
    if [[ -n "$macgo_previous_legacy" && -d "$macgo_previous_legacy" ]]; then
        if move_to_empty_path "$macgo_previous_legacy" "$macgo_legacy"; then
            "$macgo_registrar" -f "$macgo_legacy" || failed=1
        else failed=1; fi
    fi
    return "$failed"
}

finish_install() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$status" != 0 && "$macgo_committed" == 0 ]]; then
        if ! rollback_install; then
            printf 'Automatic rollback could not finish; retained recovery files: %s\n' "$macgo_stage" >&2
        fi
    fi
    # Only empty, task-owned directories are removed. Bundles are never deleted.
    if [[ -n "$macgo_stage" ]]; then rmdir "$macgo_stage" 2>/dev/null || true; fi
    rmdir "$macgo_lock" 2>/dev/null || true
    exit "$status"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

macgo_stage="$(mktemp -d "$macgo_install_dir/.macgo-install.XXXXXX")"
macgo_staged_app="$macgo_stage/Mac Go.app"
ditto "$macgo_source" "$macgo_staged_app"
require_macgo_bundle "$macgo_staged_app"
codesign --verify --deep --strict "$macgo_staged_app"
require_no_running_app

# Check the exact existing paths again immediately before moving each one.
if [[ -e "$macgo_destination" || -L "$macgo_destination" ]]; then
    require_macgo_bundle "$macgo_destination"
    macgo_previous="$macgo_stage/previous.app"
    move_to_empty_path "$macgo_destination" "$macgo_previous"
fi
if [[ -e "$macgo_legacy" || -L "$macgo_legacy" ]]; then
    require_macgo_bundle "$macgo_legacy"
    macgo_previous_legacy="$macgo_stage/previous-legacy.app"
    move_to_empty_path "$macgo_legacy" "$macgo_previous_legacy"
fi
move_to_empty_path "$macgo_staged_app" "$macgo_destination"
macgo_published=1
touch "$macgo_destination"

# Retire only the exact former canonical path after its bundle has moved away.
# Do not register hidden backups, dist artifacts, or any unrelated application.
if [[ -n "$macgo_previous_legacy" ]]; then
    "$macgo_registrar" -u "$macgo_legacy"
fi
macgo_registration_attempted=1
"$macgo_registrar" -f "$macgo_destination"
macgo_committed=1
printf 'Installed and registered: %s\n' "$macgo_destination"
if [[ -n "$macgo_previous" ]]; then printf 'Previous Mac Go retained: %s\n' "$macgo_previous"; fi
if [[ -n "$macgo_previous_legacy" ]]; then printf 'Previous Mac 工具箱 retained: %s\n' "$macgo_previous_legacy"; fi
# This script does not launch apps, install the privileged fan service, reset
# permissions, change TCC records, or alter hardware fan settings.
