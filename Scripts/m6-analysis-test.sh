#!/bin/zsh
# M6 验收用：后台分析与搜索（PHOTOAI_SCENARIO=analysis）。不需要卡插着，要先装人脸识别模型。
# 用法：Scripts/m6-analysis-test.sh <工作目录>
#
# 1. 复制真实库到 <工作目录>/lib-m6（数据库用 .backup，预览用 APFS 克隆），不改用户的库；
#    副本升级到 M6 的表结构时，所有照片的 OCR、人物都是“待做”；
# 2. 打开软件走场景：暂停、续跑、全部做完后搜索、人物命名、“不是 TA”、移除卷后搜不到。
# 场景会改本机设置里的“暂停了哪些分析”，前后都清掉。
set -euo pipefail

work=${1:?用法：Scripts/m6-analysis-test.sh <工作目录>}
project_directory=${0:A:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"

cd "$project_directory"
Scripts/build-app.sh >/dev/null

rm -rf "$work/lib-m6" "$work/snap-m6"
mkdir -p "$work/lib-m6" "$work/snap-m6"
sqlite3 "$library/library.sqlite" ".backup '$work/lib-m6/library.sqlite'"
cp -cR "$library/Previews" "$work/lib-m6/Previews"

defaults delete local.photoai.mac.v2 analysisPaused 2>/dev/null || true
trap 'defaults delete local.photoai.mac.v2 analysisPaused 2>/dev/null || true' EXIT
PHOTOAI_LIBRARY_DIR=$work/lib-m6 PHOTOAI_SCENARIO=analysis PHOTOAI_SNAPSHOT_DIR=$work/snap-m6 PHOTOAI_MEASURE=1 \
  .build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp
