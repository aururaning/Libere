# 验证记录 · Libere 0.7.0

2026-11-24，Apple Silicon Mac，Xcode 27.2，build 26。

| 检查 | 最终结果 |
| --- | --- |
| XCTest | 132 项通过，0 失败 |
| 原生回归（优化编译） | 1568 项通过 |
| Agent 桥接 | 18 项通过 |
| Apple SDK | Mac、iPad Simulator、iPad device 全部 BUILD SUCCEEDED |
| 工程结构 | 71 个 Swift 源文件各包含一次 |

新增或扩展检查涵盖：多选整组事务与五档缩放搜索定位；Clipboard/Wiki/Finder固定目标/真实WK链接；标题IME与物理改名/撤销/冲突/迟到提交；回收站确认与永久清除防复活；锁定删除；RTF真实字体、连续字号及自动增高单undo；阅读窗复用、页码和键盘、关闭失败保留、非key窗口IME先提交后判定；Notebook单元结构、busy输入与稳定ID/代次抵御迟到编辑；iCloud手动批量释放的安全条件。

全部测试在合成资料库执行，未对用户资料执行删除/永久清除/释放，也未重启用户应用。首轮与收尾失败记录保留：字体系统名写入RTF后规范化为HelveticaNeue，曾误记no-op撤销；已按实际持久化字体身份修正。单元结构变更后旧index回调已改为稳定ID+代次并覆盖真实marked-text拆卸。新资料格式3及最小永久清除标记通过旧备份/历史/previous/迟到保存/Agent重试过滤。

本机证据：.build/validation/check-0.7.0-release.log、native-0.7.0-release.log。新增原生入口在CanvasBatchNativeChecks、ClipboardLinksNativeChecks、PageManagementNativeChecks、ReaderNotebookNativeChecks；新增Core测试在CanvasBatchTests、PermanentDeletionTests、NotebookOperationsTests、SearchAndLinksTests。

原生与离屏验证不等于真实设备操作验收。目录书签和真实loopback通信保持明确跳过，不计入通过数量；真实iCloud双设备、Pencil/Sidecar未验收。安装包仅本地临时签名、未Apple公证。
