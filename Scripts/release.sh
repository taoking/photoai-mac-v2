#!/bin/zsh
# 打包一个阶段版本：构建 release 版的 .app，压成 zip，算 SHA-256。
# 用法：Scripts/release.sh <版本>            只打包，输出 .build/release-zips/PhotoAI-v2-<版本>.zip
#       Scripts/release.sh <版本> --publish  再打 tag v<版本> 并在 GitHub 发 Release（说明取 docs/迭代.md 的版本表）
# 版本号要先改进 Resources/Info.plist（CFBundleShortVersionString），两边不一致就停。
set -euo pipefail

version=${1:?用法：Scripts/release.sh <版本> [--publish]}
project_directory=${0:A:h:h}
cd "$project_directory"

plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ $plist_version != "$version" ]]; then
    echo "Info.plist 里的版本是 $plist_version，不是 $version" >&2
    exit 1
fi

app=$(Scripts/build-app.sh release | tail -1)
output_directory=.build/release-zips
mkdir -p "$output_directory"
zip=$output_directory/PhotoAI-v2-$version.zip
rm -f "$zip"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$zip"
digest=$(shasum -a 256 "$zip" | cut -d ' ' -f 1)
echo "$zip"
echo "SHA-256 $digest"

[[ ${2:-} == --publish ]] || exit 0
if [[ -n $(git status --porcelain) ]]; then
    echo "工作区有没提交的改动，不发布" >&2
    exit 1
fi
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
{
    grep -E "^\| $version \|" docs/迭代.md | cut -d '|' -f 4 | sed 's/^ *//; s/ *$//'
    echo
    echo "需要 macOS 27.2 或更新（Apple 芯片）。安装、升级、命令行和人物识别模型见 [安装与部署](https://github.com/taoking/photoai-mac-v2/blob/main/安装与部署.md)，功能见 [功能说明](https://github.com/taoking/photoai-mac-v2/blob/main/功能说明.md)。"
    echo
    echo "只给自己用：本机临时签名（没有 Developer ID、没有公证）。从网页下载后第一次打开会被系统拦下，"
    echo "解压后运行 \`xattr -dr com.apple.quarantine PhotoAI-v2.app\` 再打开，或者直接用源码 \`Scripts/install.sh\` 构建安装。"
    echo "人物识别要的模型不在包里，用源码里的 \`Scripts/install-face-model.sh\` 在本机下载转换。"
    echo
    echo "SHA-256：\`$digest\`"
} > "$notes"
git tag -a "v$version" -m "PhotoAI v2 $version"
git push origin "v$version"
gh release create "v$version" "$zip" --title "PhotoAI v2 $version" --notes-file "$notes"
