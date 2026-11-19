# PhotoAI Mac v2

PhotoAI Mac 的重写项目：只给自己用的本机选片工作台，同时是所有导入过照片的预览档案。

- 记住每张照片在哪张卡、哪块盘上，在本机永久留一份预览；卡和盘拔掉、清空以后照样能浏览和选片。
- 星级 + 自定义标签 + 收藏夹，选好后导出原文件去别处精修。
- 从不改动、移动、删除卡和外置盘上的文件。

当前状态：设计与可点击原型已确认；原生应用（macOS 27，SwiftUI）M1“卷与导入”代码完成，等真实卡验收。v1 在另一个项目里，继续可用。

## 从这里开始

- [交接](交接.md)：现在在哪一步、下一步做什么、文档地图、最容易做错的规则。
- [设计稿](docs/设计稿.md)：最终结论汇总，以它为准。
- [计划](docs/计划.md)：阶段、验收标准、性能目标、工作方式。
- [沟通记录](docs/沟通记录.md)：每轮讨论的问答。

细节文档：[产品定位与目标](docs/产品定位与目标.md)、[信息架构与交互](docs/信息架构与交互.md)、[数据模型](docs/数据模型.md)。

## 构建

需要 Xcode 27（Swift 6.4）。

```sh
swift test                                # 自动测试
Scripts/build-app.sh && open .build/PhotoAI-v2.app
swift run photoai exif <照片>…             # 查看身份相关的 EXIF 字段
```

## 原型

```sh
open prototype/index.html      # 浏览器直接打开，不联网，数据只在内存里
prototype/tests/run.sh         # 无界面 Chrome 走一遍典型场景（需要 Google Chrome）
```
