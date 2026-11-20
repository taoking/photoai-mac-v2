#!/bin/zsh
# 从文件导入星级（PHOTOAI_SCENARIO=ratingimport）。不需要卡插着。
# 用法：Scripts/rating-import-test.sh <工作目录>
# 复制真实库到 <工作目录>/lib-rating（数据库用 .backup，预览用 APFS 克隆），确认面板的截图放 <工作目录>/snap-rating。
set -euo pipefail

work=${1:?用法：Scripts/rating-import-test.sh <工作目录>}
project_directory=${0:A:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"

cd "$project_directory"
Scripts/build-app.sh >/dev/null

rm -rf "$work/lib-rating" "$work/snap-rating"
mkdir -p "$work/lib-rating" "$work/snap-rating"
sqlite3 "$library/library.sqlite" ".backup '$work/lib-rating/library.sqlite'"
cp -cR "$library/Previews" "$work/lib-rating/Previews"

PHOTOAI_LIBRARY_DIR=$work/lib-rating PHOTOAI_SCENARIO=ratingimport PHOTOAI_SNAPSHOT_DIR=$work/snap-rating PHOTOAI_ANALYSIS=off PHOTOAI_FOCUS=off \
  .build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp
rm -rf "$work/lib-rating"
