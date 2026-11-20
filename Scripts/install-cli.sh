#!/bin/zsh
# 安装命令行工具和 Claude skill：
# - photoai 复制到 ~/.local/bin（要在 PATH 里）；
# - Skills/photoai 链接到 ~/.claude/skills/photoai，改仓库里的 SKILL.md 就是改装好的 skill。
# 用法：Scripts/install-cli.sh        卸载：Scripts/install-cli.sh --uninstall
set -euo pipefail

project_directory=${0:A:h:h}
bin_directory="$HOME/.local/bin"
skill_link="$HOME/.claude/skills/photoai"

if [[ ${1:-} == --uninstall ]]; then
    rm -f "$bin_directory/photoai"
    [[ -L $skill_link ]] && rm "$skill_link"
    echo "已卸载"
    exit 0
fi

cd "$project_directory"
swift build --configuration release --product photoai
mkdir -p "$bin_directory" "${skill_link:h}"
install -m 0755 "$(swift build --configuration release --show-bin-path)/photoai" "$bin_directory/photoai"
if [[ -e $skill_link && ! -L $skill_link ]]; then
    echo "$skill_link 已存在而且不是链接，没有覆盖" >&2
    exit 1
fi
ln -sfn "$project_directory/Skills/photoai" "$skill_link"

echo "photoai → $bin_directory/photoai"
echo "skill → $skill_link"
[[ :$PATH: == *:$bin_directory:* ]] || echo "注意：$bin_directory 不在 PATH 里" >&2
