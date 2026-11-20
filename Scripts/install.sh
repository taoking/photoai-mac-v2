#!/bin/zsh
# 从源码安装：构建 release 版的 .app，装到 /Applications/PhotoAI-v2.app（已有的旧版本被替换，照片库不受影响）。
# 用法：Scripts/install.sh          只装软件
#       Scripts/install.sh --cli    再装命令行工具和 Claude skill（Scripts/install-cli.sh）
set -euo pipefail

project_directory=${0:A:h:h}
target=/Applications/PhotoAI-v2.app
cd "$project_directory"

if pgrep -x PhotoAIApp >/dev/null; then
    echo "PhotoAI v2 正在运行，先退出（⌘Q）再安装" >&2
    exit 1
fi

app=$(Scripts/build-app.sh release | tail -1)
rm -rf "$target"
ditto "$app" "$target"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
echo "PhotoAI v2 $version → $target"

[[ ${1:-} == --cli ]] && Scripts/install-cli.sh
exit 0
