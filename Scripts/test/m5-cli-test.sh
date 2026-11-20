#!/bin/zsh
# M5 验收用：命令行和软件一起用（PHOTOAI_SCENARIO=cli）。不需要卡插着。
# 用法：Scripts/test/m5-cli-test.sh <工作目录>
#
# 1. 复制真实库到 <工作目录>/lib-m5（数据库用 .backup，预览用 APFS 克隆），不改用户的库；
# 2. 软件关闭时用命令行打 3 星、加入「命令行·关闭时」；
# 3. 打开软件走场景：核对第 2 步的结果，再在软件开着时跑命令行，切回窗口后核对刷新。
set -euo pipefail

work=${1:?用法：Scripts/test/m5-cli-test.sh <工作目录>}
project_directory=${0:A:h:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"

cd "$project_directory"
swift build --configuration release --product photoai >/dev/null
Scripts/build-app.sh >/dev/null
cli=$(swift build --configuration release --show-bin-path)/photoai

rm -rf "$work/lib-m5"
mkdir -p "$work/lib-m5"
sqlite3 "$library/library.sqlite" ".backup '$work/lib-m5/library.sqlite'"
cp -cR "$library/Previews" "$work/lib-m5/Previews"
export PHOTOAI_LIBRARY_DIR=$work/lib-m5

# 从最新的照片里挑：一个文件名、两个编号、一个编号范围（关闭时），另一个编号范围（开着时）。
newest() { sqlite3 "$work/lib-m5/library.sqlite" "SELECT $1 FROM photos WHERE present_location_count > 0 AND file_number IS NOT NULL ORDER BY capture_date DESC LIMIT 1 OFFSET $2;" }
n10=$(newest file_number 10)
n30=$(newest file_number 30)
closed="$(newest base_name 0) $(newest file_number 1),$(newest file_number 2) $n10-$((n10 + 3))"
open_terms="$n30-$((n30 + 4))"

echo "== 软件关闭时：photoai rate 3 / collect，匹配项 $closed"
"$cli" rate 3 ${=closed}
"$cli" collect "命令行·关闭时" ${=closed}
echo "== 打开软件，开着时的匹配项 $open_terms"
PHOTOAI_SCENARIO=cli PHOTOAI_CLI=$cli PHOTOAI_CLI_CLOSED=$closed PHOTOAI_CLI_OPEN=$open_terms \
  PHOTOAI_SNAPSHOT_DIR=$work/snap .build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp
