#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# < 3 )) || [[ "$1" != "--output" ]]; then
    echo '用法：Scripts/check-color-spots.sh --output <诊断目录> <照片>...'
    exit 1
fi
swift build --disable-sandbox --product PortraitRetouch
build_bin_dir="$(swift build --disable-sandbox --show-bin-path)"
# Xcode Swift Build and the classic SwiftPM layout expose different object paths.
if [[ -f "$build_bin_dir/ColorEngine.o" ]]; then
    engine_objects=("$build_bin_dir/ColorEngine.o")
else
    engine_objects=("$build_bin_dir"/ColorEngine.build/*.o)
fi
swiftc -parse-as-library -I "$build_bin_dir" -I "$build_bin_dir/Modules" \
    Scripts/color-spot-qa.swift "${engine_objects[@]}" -o "$build_bin_dir/ColorSpotQA"
"$build_bin_dir/ColorSpotQA" "$@"
