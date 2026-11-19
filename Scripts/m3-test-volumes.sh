#!/bin/zsh
# M3 验收用：准备导出与放大场景（PHOTOAI_SCENARIO=export）要的库副本和两个测试磁盘映像。
# 用法：Scripts/m3-test-volumes.sh <工作目录> [真实卡的挂载点，默认 /Volumes/Untitled]
#
# - <工作目录>/lib-m3：真实库的副本（数据库用 .backup，预览用 APFS 克隆），不改用户的库；
# - PAICARDA（卡 A）、PAIBACKUP（备份盘 B）：exFAT 映像，放从真实卡复制并改名的 6 组照片。
#   TST00001 两边都有，TST00002 的 JPG 在 B 上也有，TST00003–5 只在 A，TST00006 只在 B。
#   场景会删掉 A 上的几个文件、推出 B；真实卡只读。
set -euo pipefail

work=${1:?用法：Scripts/m3-test-volumes.sh <工作目录> [真实卡的挂载点]}
card=${2:-/Volumes/Untitled}
project_directory=${0:A:h:h}
library="$HOME/Library/Application Support/PhotoAI-Mac-v2"

mkdir -p "$work"
rm -rf "$work/lib-m3"
mkdir -p "$work/lib-m3"
sqlite3 "$library/library.sqlite" ".backup '$work/lib-m3/library.sqlite'"
cp -cR "$library/Previews" "$work/lib-m3/Previews"

for volume in PAICARDA PAIBACKUP; do
    [[ -d /Volumes/$volume ]] && hdiutil detach -force /Volumes/$volume >/dev/null
done
hdiutil create -size 700m -fs ExFAT -volname PAICARDA -ov "$work/card-a.dmg" >/dev/null
hdiutil create -size 500m -fs ExFAT -volname PAIBACKUP -ov "$work/backup-b.dmg" >/dev/null
hdiutil attach "$work/card-a.dmg" >/dev/null
hdiutil attach "$work/backup-b.dmg" >/dev/null
mkdir -p /Volumes/PAICARDA/DCIM/100MSDCF /Volumes/PAIBACKUP/备份

sources=("$card"/DCIM/*/*.JPG(N))
sources=(${sources[1,6]})
index=1
for jpeg in $sources; do
    base=${jpeg%.JPG}
    name=$(printf "TST%05d" $index)
    if (( index <= 5 )); then
        cp -p "$base.JPG" /Volumes/PAICARDA/DCIM/100MSDCF/$name.JPG
        cp -p "$base.ARW" /Volumes/PAICARDA/DCIM/100MSDCF/$name.ARW
    fi
    if (( index == 1 || index == 6 )); then
        cp -p "$base.JPG" /Volumes/PAIBACKUP/备份/$name.JPG
        cp -p "$base.ARW" /Volumes/PAIBACKUP/备份/$name.ARW
    fi
    (( index == 2 )) && cp -p "$base.JPG" /Volumes/PAIBACKUP/备份/$name.JPG
    (( index++ ))
done

cd "$project_directory"
swift build --product photoai >/dev/null
photoai=$(swift build --show-bin-path)/photoai
PHOTOAI_LIBRARY_DIR="$work/lib-m3" "$photoai" dev-import /Volumes/PAICARDA
PHOTOAI_LIBRARY_DIR="$work/lib-m3" "$photoai" dev-import /Volumes/PAIBACKUP

cat <<EOF

准备好了。运行场景：
PHOTOAI_LIBRARY_DIR=$work/lib-m3 PHOTOAI_SCENARIO=export PHOTOAI_MEASURE=1 PHOTOAI_EXPORT_DIR=$work/m3-out \\
  PHOTOAI_SNAPSHOT_DIR=$work/snap PHOTOAI_SCENARIO_BACKUP_DMG=$work/backup-b.dmg .build/PhotoAI-v2.app/Contents/MacOS/PhotoAIApp
EOF
