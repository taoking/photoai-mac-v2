"""把 InsightFace 的 ArcFace 模型（w600k_r50.onnx）转成 Core ML。

由 Scripts/install-face-model.sh 在临时的 uv 环境里调用，不单独运行。
输入：112×112 对齐好的人脸，RGB，像素按 (x - 127.5) / 127.5 归一化（写进 Core ML 的图像输入，调用方直接给图）。
输出：512 维特征向量 `feature`，没有归一化，调用方自己做 L2 归一化。
"""
import sys

import coremltools as ct
import onnx
import torch
from onnx2torch import convert

source, destination = sys.argv[1], sys.argv[2]
model = convert(onnx.load(source)).eval()
example = torch.rand(1, 3, 112, 112)
traced = torch.jit.trace(model, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="face", shape=example.shape, scale=1 / 127.5, bias=[-1, -1, -1],
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="feature")],
    minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "ArcFace R50（InsightFace buffalo_l / w600k_r50），仅限非商业用途"
mlmodel.save(destination)

# 核对：同一张随机图在 PyTorch 和 Core ML 里的输出方向一致。
import numpy as np
from PIL import Image

pixels = (np.random.rand(112, 112, 3) * 255).astype(np.uint8)
reference = model(torch.from_numpy((pixels.astype(np.float32) - 127.5) / 127.5).permute(2, 0, 1)[None]).detach().numpy()[0]
predicted = np.asarray(ct.models.MLModel(destination).predict({"face": Image.fromarray(pixels)})["feature"]).reshape(-1)
cosine = float(np.dot(reference, predicted) / np.linalg.norm(reference) / np.linalg.norm(predicted))
print(f"PyTorch 与 Core ML 输出的余弦相似度：{cosine:.4f}")
if cosine < 0.99:
    sys.exit("转换结果和原模型差得太多")
