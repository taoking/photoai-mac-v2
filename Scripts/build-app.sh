#!/bin/zsh
# 构建可双击打开的 .app（不签名发布，只做本机的临时签名）。用法：Scripts/build-app.sh [debug|release]
set -euo pipefail

configuration=${1:-release}
project_directory=${0:A:h:h}
app_directory="$project_directory/.build/PhotoAI-v2.app"

cd "$project_directory"
swift build --configuration "$configuration" --product PhotoAIApp
binary_directory=$(swift build --configuration "$configuration" --show-bin-path)

rm -rf "$app_directory"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
install -m 0644 "$project_directory/Resources/Info.plist" "$app_directory/Contents/Info.plist"
install -m 0755 "$binary_directory/PhotoAIApp" "$app_directory/Contents/MacOS/PhotoAIApp"
codesign --force --sign - "$app_directory"

echo "$app_directory"
