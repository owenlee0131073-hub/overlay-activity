#!/bin/bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/overlay-activity.XXXXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT

staged_app="$build_dir/Overlay Activity.app"
output_app="$project_dir/dist/Overlay Activity.app"
mkdir -p "$staged_app/Contents/MacOS" "$project_dir/dist"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"

swift build --package-path "$project_dir" --configuration release --product OverlayActivity "$@"
bin_dir=$(swift build --package-path "$project_dir" --configuration release --show-bin-path "$@")
cp "$bin_dir/OverlayActivity" "$staged_app/Contents/MacOS/OverlayActivity"
codesign --sign - "$staged_app"
ditto "$staged_app" "$output_app"
printf '%s\n' "$output_app"
