#!/bin/zsh
# 检查器（直方图、导航器）对流畅度的影响：PF-2、PF-6、PF-7。不需要卡插着，只用真实库的副本。
# 用法：Scripts/inspector-pf.sh <工作目录>
#
# 后台分析关着（只看检查器本身），检查器开着（默认），三项：
# - PF-2：网格每 1/60 秒向下滚 150 点，600 帧；
# - PF-6 / PF-7：单张视图连续打星、自动前进，每 40 ms 一次 1,000 次，和按人的节奏每 450 ms 一次 150 次。
# 每次都重新复制库。改代码前后各跑一次比较。
set -uo pipefail

work=${1:?用法：Scripts/inspector-pf.sh <工作目录>}
project_directory=${0:A:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"
app=$project_directory/.build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp

cd "$project_directory"
Scripts/build-app.sh >/dev/null

fresh() {
    rm -rf "$work/lib-pf"
    mkdir -p "$work/lib-pf"
    sqlite3 "$library/library.sqlite" ".backup '$work/lib-pf/library.sqlite'"
    cp -cR "$library/Previews" "$work/lib-pf/Previews"
}

common=(PHOTOAI_LIBRARY_DIR=$work/lib-pf PHOTOAI_MEASURE=1 PHOTOAI_ANALYSIS=off)
fresh
env $common PHOTOAI_SCROLL_TEST=1 PHOTOAI_SCROLL_DELAY=4 "$app" 2>&1 | grep -E "PF-2"
fresh
env $common PHOTOAI_SCENARIO=cull1000 PHOTOAI_SCENARIO_DELAY=4 "$app" 2>&1 | grep -E "PF-6|PF-7|场景"
fresh
env $common PHOTOAI_SCENARIO=cull1000 PHOTOAI_SCENARIO_DELAY=4 PHOTOAI_CULL_COUNT=150 PHOTOAI_CULL_INTERVAL_MS=450 \
    "$app" 2>&1 | grep -E "PF-6|PF-7|场景"
rm -rf "$work/lib-pf"
