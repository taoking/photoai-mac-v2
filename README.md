# PhotoAI Mac v2

只给自己用的本机选片工作台，同时是所有导入过照片的预览档案。

- 记住每张照片在哪张卡、哪块盘上，在本机永久留一份预览；卡和盘拔掉、清空以后照样能浏览和选片。
- 星级 + 自定义标签 + Pick / Reject + 收藏夹，选好后导出原文件去别处精修。
- 清卡前按文件核对副本，缺的补到备份盘；人物分组、照片里的文字、地点、日期都能搜。
- 命令行 `photoai` 和 Claude skill：“把 1926 到 1950 打 5 星”。
- 从不改动、移动、删除卡和外置盘上的文件。

当前版本 **1.0.0**（[Releases](https://github.com/taoking/photoai-mac-v2/releases)）。需要 **macOS 27.2 或更新**、Apple 芯片。v1 在另一个项目里，继续可用。

## 文档

| 文档 | 内容 |
| --- | --- |
| [安装与部署](安装与部署.md) | 系统要求、安装、升级、人物识别模型、命令行和 skill、数据位置、备份、卸载、常见问题 |
| [功能说明](功能说明.md) | 每项功能怎么用、快捷键总表、版本 |
| [开发文档](docs/README.md) | 交接、设计、后续迭代、开发过程记录 |

## 快速安装

```sh
git clone https://github.com/taoking/photoai-mac-v2.git && cd photoai-mac-v2
Scripts/install.sh --cli          # 软件装到 /Applications，命令行和 skill 装到本机
Scripts/install-face-model.sh     # 可选：人物识别要的模型（下载后在本机转换）
```

也可以在 [Releases](https://github.com/taoking/photoai-mac-v2/releases) 下载打包好的 `.app`，第一次打开前的步骤见[安装与部署](安装与部署.md#方式二下载-release)。

## 目录

```text
安装与部署.md  功能说明.md     给使用者看的文档
Sources/       PhotoAICore（数据、扫描、预览、导出、清卡、分析）、PhotoAIApp（SwiftUI 界面）、photoai（命令行）
Tests/         自动测试（swift test）
Resources/     Info.plist、应用图标
Scripts/       构建、安装、打包发布、模型安装、图标；Scripts/test/ 是验收场景和性能测量脚本
Skills/        Claude skill（photoai）
docs/          开发文档：交接、设计、迭代、过程记录，已冻结的网页原型
```

## 开发

需要 Xcode 27（Swift 6.4）。

```sh
swift test                                          # 自动测试
Scripts/build-app.sh && open .build/PhotoAI-v2.app  # 构建（不安装）
Scripts/release.sh 1.0.0                            # 打包 zip；加 --publish 发 GitHub Release
```

接手开发先读 [交接](docs/交接.md)。人脸识别模型（InsightFace ArcFace R50）的协议只允许非商业用途，不放进仓库，由脚本下载到本机。
