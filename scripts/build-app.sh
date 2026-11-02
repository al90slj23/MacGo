#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

toolbox_expected_id="local.mactoolbox.app"
toolbox_output="$PWD/dist/Mac Go.app"
require_toolbox_bundle() {
    local candidate="$1"
    [[ -d "$candidate" && ! -L "$candidate" ]] || {
        printf 'Refusing unexpected app path: %s\n' "$candidate" >&2; return 1;
    }
    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")"
    [[ "$bundle_id" == "$toolbox_expected_id" ]] || {
        printf 'Refusing unrelated app at: %s\n' "$candidate" >&2; return 1;
    }
}
if [[ -e "$toolbox_output" || -L "$toolbox_output" ]]; then
    require_toolbox_bundle "$toolbox_output"
fi

swift build -c release --product MacGo
swift build -c release --product MacToolboxFanHelper
toolbox_bin="$(swift build -c release --show-bin-path)"
mkdir -p "$PWD/dist"
toolbox_stage="$(mktemp -d "$PWD/dist/.macgo-build.XXXXXX")"
toolbox_app="$toolbox_stage/Mac Go.app"
# Remove only an empty task-created stage; retain partial builds/previous artifacts
# for inspection instead of deleting files on failure.
trap 'rmdir "$toolbox_stage" 2>/dev/null || true' EXIT
mkdir -p "$toolbox_app/Contents/MacOS" "$toolbox_app/Contents/Resources" "$toolbox_app/Contents/Library/LaunchDaemons"
cp "$toolbox_bin/MacGo" "$toolbox_app/Contents/MacOS/MacGo"
cp "$toolbox_bin/MacToolboxFanHelper" "$toolbox_app/Contents/MacOS/MacToolboxFanHelper"
cp Resources/Info.plist "$toolbox_app/Contents/Info.plist"
cp Resources/local.mactoolbox.fan-helper.plist "$toolbox_app/Contents/Library/LaunchDaemons/"
cp Sources/SMCController/Stats-MIT.txt "$toolbox_app/Contents/Resources/Stats-MIT.txt"
cp Resources/AppIcon.icns "$toolbox_app/Contents/Resources/AppIcon.icns"
toolbox_identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$toolbox_identity" --identifier local.mactoolbox.fan-helper "$toolbox_app/Contents/MacOS/MacToolboxFanHelper"
codesign --force --options runtime --sign "$toolbox_identity" --identifier local.mactoolbox.app "$toolbox_app"
codesign --verify --deep --strict "$toolbox_app"
touch "$toolbox_app"

toolbox_previous=""
if [[ -e "$toolbox_output" || -L "$toolbox_output" ]]; then
    require_toolbox_bundle "$toolbox_output"
    toolbox_previous="$toolbox_stage/previous.app"
    mv "$toolbox_output" "$toolbox_previous"
fi
if ! mv "$toolbox_app" "$toolbox_output"; then
    if [[ -n "$toolbox_previous" ]]; then mv "$toolbox_previous" "$toolbox_output"; fi
    printf 'Failed to publish app; staged files retained at: %s\n' "$toolbox_stage" >&2
    exit 1
fi
printf 'Built: %s\n' "$toolbox_output"
if [[ -n "$toolbox_previous" ]]; then printf 'Previous artifact retained: %s\n' "$toolbox_previous"; fi
# Build artifacts are deliberately not registered with Launch Services. Use the
# separate installer to register only the canonical user Applications copy.
