#!/bin/zsh
# PF-12：后台人物、OCR 运行时 PF-2、PF-6、PF-7 不退化。不需要卡插着，要先装人脸识别模型。
# 用法：Scripts/test/m6-pf12.sh <工作目录>
#
# 同一份数据（真实库的副本，分析全是“待做”）、同一台机器、同样的操作，跑三遍：
#   off：后台分析关（PHOTOAI_ANALYSIS=off）；
#   on-worst：分析开，用户操作时也不让路（PHOTOAI_ANALYSIS_YIELD=off），最坏情况；
#   on：分析开，和平时一样，用户操作后 0.6 秒内让路。
# - PF-2：网格每 1/60 秒向下滚 150 点，600 帧（PHOTOAI_SCROLL_TEST），等分析开始后再滚；
# - PF-6 / PF-7：单张视图连续打星、自动前进，每 40 ms 一次 1,000 次，和按人的节奏每 450 ms 一次 150 次。
# 打星场景每次调命令前记一次“用户在操作”，和真按键一样；滚动测试是程序滚的，不记，分析一直在跑。
# 每次都重新复制库，分析从头开始。
set -uo pipefail

work=${1:?用法：Scripts/test/m6-pf12.sh <工作目录>}
project_directory=${0:A:h:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"
app=$project_directory/.build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp

cd "$project_directory"
Scripts/build-app.sh >/dev/null
defaults delete local.photoai.mac.v2 analysisPaused 2>/dev/null || true

fresh() {
    rm -rf "$work/lib-pf12"
    mkdir -p "$work/lib-pf12"
    sqlite3 "$library/library.sqlite" ".backup '$work/lib-pf12/library.sqlite'"
    cp -cR "$library/Previews" "$work/lib-pf12/Previews"
}

for mode in off on-worst on; do
    echo "===== 后台分析：$mode"
    common=(PHOTOAI_LIBRARY_DIR=$work/lib-pf12 PHOTOAI_MEASURE=1 PHOTOAI_ANALYSIS=${mode%%-*})
    [[ $mode == on-worst ]] && common+=(PHOTOAI_ANALYSIS_YIELD=off)
    fresh
    env $common PHOTOAI_SCROLL_TEST=1 PHOTOAI_SCROLL_DELAY=8 "$app" 2>&1 | grep -E "PF-2|分析开始"
    fresh
    env $common PHOTOAI_SCENARIO=cull1000 PHOTOAI_SCENARIO_DELAY=6 "$app" 2>&1 | grep -E "PF-6|PF-7|分析开始|场景"
    fresh
    env $common PHOTOAI_SCENARIO=cull1000 PHOTOAI_SCENARIO_DELAY=6 PHOTOAI_CULL_COUNT=150 PHOTOAI_CULL_INTERVAL_MS=450 \
        "$app" 2>&1 | grep -E "PF-6|PF-7|分析开始|场景"
done
rm -rf "$work/lib-pf12"
