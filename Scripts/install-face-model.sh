#!/bin/zsh
# 下载人脸识别模型并转成 Core ML，人物识别要用（设计稿 §10）。
#
# 模型是 InsightFace 的 ArcFace R50（buffalo_l 里的 w600k_r50.onnx），协议只允许非商业用途，
# 所以不进仓库：下载到缓存目录，转换后放到
#   ~/Library/Application Support/PhotoAI-Mac-v2/Models/ArcFace-R50.mlmodelc
# 软件和命令行都从这里读（环境变量 PHOTOAI_FACE_MODEL 可以换成别处）。
#
# 转换要 PyTorch、coremltools，用 uv 建一个隔离的临时环境（约 1 GB，留在 uv 的缓存里，`uv cache clean` 可以清掉）。
# 用法：Scripts/install-face-model.sh [已经下载好的 buffalo_l.zip]
set -euo pipefail

project_directory=${0:A:h:h}
zip_url=https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
zip_sha256=80ffe37d8a5940d59a7384c201a2a38d4741f2f3c51eef46ebb28218a7b0ca2f
cache_directory="$HOME/Library/Caches/PhotoAI-Mac-v2/face-model"
model_directory="$HOME/Library/Application Support/PhotoAI-Mac-v2/Models"
model_name=ArcFace-R50

command -v uv >/dev/null || { echo "要先装 uv：https://docs.astral.sh/uv/" >&2; exit 1; }
mkdir -p "$cache_directory" "$model_directory"

zip_path=${1:-$cache_directory/buffalo_l.zip}
if [[ ! -f $zip_path ]]; then
    echo "下载 $zip_url（约 280 MB）…"
    curl --fail --location --output "$zip_path.part" "$zip_url"
    mv "$zip_path.part" "$zip_path"
fi
actual=$(shasum -a 256 "$zip_path" | cut -d ' ' -f 1)
if [[ $actual != "$zip_sha256" ]]; then
    echo "下载的文件校验不对：$actual" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q -j "$zip_path" w600k_r50.onnx -d "$work"

echo "转换成 Core ML…"
uv run --isolated --no-project --python 3.12 \
    --with torch==2.5.1 --with onnx==1.17.0 --with onnx2torch==1.5.15 --with coremltools==8.3.0 \
    --with numpy==2.1.3 --with pillow==11.1.0 \
    python -I "$project_directory/Scripts/convert-face-model.py" "$work/w600k_r50.onnx" "$work/$model_name.mlpackage"
xcrun coremlcompiler compile "$work/$model_name.mlpackage" "$work" >/dev/null

rm -rf "$model_directory/$model_name.mlmodelc"
mv "$work/$model_name.mlmodelc" "$model_directory/"
echo "模型 → $model_directory/$model_name.mlmodelc"
