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

2026-11-20，0.6.10（build 22）源码在 Apple Silicon、Xcode 27.2 环境通过 `Scripts/check.sh`：83 个 XCTest、18 个 Agent 桥接测试，以及 Mac / iPad Simulator / iPad 设备 SDK 构建。`Scripts/check-native.sh` 和 `Scripts/check-native.sh --optimized` 各通过 1285 项原生断言，包含 23 项侧栏、引用刷新与按需加载检查。

Mac 可执行文件以 `-O -whole-module-optimization` 构建。应用和安装包均包含 LICENSE、NOTICE 与第三方依赖声明；PKG 解包后 16 个应用文件与原构建逐一一致，严格签名校验通过。安装目标固定为 `/Applications/Libere.app`，无安装脚本。打包验证未实际运行安装器；以上不表示 GitHub Actions 已执行。

## 大资料库性能检查

相同 Apple Silicon Mac、相同未优化编译参数，1000 页合成资料，每项取 3 次中位数，与公开 0.6.9 源码比较：

| 运算 | 0.6.9 | 0.6.10 |
| --- | ---: | ---: |
| 侧栏树构造 | 401.17 ms | 2.50 ms |
| 单个“移动到”候选集合 | 2314.81 ms | 0.56 ms |
| 已存在目录的同步 | 2096.61 ms | 20.73 ms |

这是独立运算耗时，不是桌面点击到页面显示的延迟。此前本机维护版 21.1 已包含菜单候选优化，本版保留并纳入公开版本。

300 个内容块的合成页面首屏只加载 2 个附近内容块；生产 NoteCanvas 的离屏原生检查验证首屏加载、远距离滚动、已加载视图保留、切页释放及五档缩放坐标。另覆盖循环/孤立层级、Unicode 摘要、目录路径一致性、当前引用与打开编辑器的外部变更，以及已有保存、撤销、批注和 PDF 锁定规则。

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
