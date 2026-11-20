# 验证范围

## 自动检查

| 检查 | 命令 | 范围 |
| --- | --- | --- |
| 工程结构 | `python3 Scripts/verify_project.py` | 工程引用、scheme、plist、源码与资源完整性 |
| 核心模型 | `bash Scripts/check-core.sh` | 文档、几何、持久化和核心逻辑断言 |
| 原生交互 | `bash Scripts/check-native.sh` | AppKit / WebKit 等原生组件、命中与编辑状态、保存和撤销 |
| XCTest 与 SDK 构建 | `bash Scripts/check.sh` | SwiftPM、Python Agent 桥接、Mac 与两种 iPad SDK 目的地 |
| Agent 实际通信 | `bash Scripts/check-native.sh --test-agent-transport` | 本机 HTTP 和 MCP 连接；需环境允许本机网络 |
| Notebook 内核 | `python3 Scripts/test_notebook_kernel.py` | Python/Jupyter 实际执行；需已安装相应依赖 |

2026-11-20，公开源码副本在 Apple Silicon、Xcode 27.2 环境中重新通过 `Scripts/check.sh`：76 个 XCTest、18 个 Agent 桥接测试，以及 Mac / iPad Simulator / iPad 设备 SDK 构建。随后通过 `Scripts/build-mac-package.sh` 完整构建并生成 PKG，解包后的应用文件与源构建一致，严格签名校验通过；安装目标固定为 `/Applications/Libere.app`，无安装脚本。

构建的应用与安装包均包含 LICENSE、NOTICE 和第三方依赖声明。打包验证没有实际执行安装器。这些是本地构建记录，不表示 GitHub Actions 已经执行。

0.6.9 开发工作树此前已完成 1262 项原生断言；应用源码与本次公开副本一致，本次公开整理未重复运行该组检查。后续修改请在相应提交上重新运行需要的检查。

## 手动验收

- 在不同缩放比例下，单击选择目标块，拖动选中块和编辑中的块；点击空白结束编辑。
- 试用中文输入法、切换页面、退出重启、撤销与重做，确认未提交文字不会丢失。
- 在附件中滚动、翻页、展开和收起，核对页内批注的位置；锁定 PDF 后预览框和预览页保持固定。
- 导入带方向信息、透明度和不同宽高比的图片；超长图按比例滚动，GIF/TIFF 只预览首帧。
- 编辑文件夹介绍，插入分类与子页面目录；备份、恢复和重启后核对结果。
- 在真实 iPad 或随航环境中检查 Pencil 输入、手指滚动、缩放及保存后的笔迹。
- 自行配置 CloudKit 后，在两台设备测试离线编辑、冲突、删除恢复和账号变化。

## 当前限制

Mac 已有构建验证使用 Apple Silicon。iPad 可以查看和编辑 Notebook，执行内核在 Mac；Python 环境不随应用提供。CloudKit 需要开发者自己的签名和容器配置。SwiftPM/原生离屏检查与 SDK 构建不代表所有桌面鼠标、硬件输入、账号权限或多设备同步情形已验收。

本地构建与生成的安装包尚未完成 Apple 发行签名和公证。应用仍处于开发阶段；升级或测试新功能前，建议先导出资料库备份。
