#!/bin/zsh
# 重新生成应用图标：Scripts/make-icon.swift 画 1024 的 PNG，转成各个尺寸，打包成 Resources/AppIcon.icns。
set -euo pipefail

project_directory=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

swift "$project_directory/Scripts/make-icon.swift" "$work" >/dev/null
for pixels in 16 32 128 256 512; do
    sips -z $pixels $pixels "$work/icon_1024.png" --out "$iconset/icon_${pixels}x${pixels}.png" >/dev/null
    sips -z $((pixels * 2)) $((pixels * 2)) "$work/icon_1024.png" --out "$iconset/icon_${pixels}x${pixels}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$project_directory/Resources/AppIcon.icns"
echo "$project_directory/Resources/AppIcon.icns"
