#!/bin/zsh
# 检查器的直方图和导航器（PHOTOAI_SCENARIO=inspector）。不需要卡插着。
# 用法：Scripts/inspector-test.sh <工作目录>
# 复制真实库到 <工作目录>/lib-inspector（数据库用 .backup，预览用 APFS 克隆），截图放 <工作目录>/snap-inspector（系统截图，要有屏幕录制权限）。
set -euo pipefail

work=${1:?用法：Scripts/inspector-test.sh <工作目录>}
project_directory=${0:A:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"

cd "$project_directory"
Scripts/build-app.sh >/dev/null

rm -rf "$work/lib-inspector" "$work/snap-inspector"
mkdir -p "$work/lib-inspector" "$work/snap-inspector"
sqlite3 "$library/library.sqlite" ".backup '$work/lib-inspector/library.sqlite'"
cp -cR "$library/Previews" "$work/lib-inspector/Previews"

PHOTOAI_LIBRARY_DIR=$work/lib-inspector PHOTOAI_SCENARIO=inspector PHOTOAI_SNAPSHOT_DIR=$work/snap-inspector PHOTOAI_ANALYSIS=off PHOTOAI_SNAPSHOT_SCREEN=1 \
  .build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp
rm -rf "$work/lib-inspector"
