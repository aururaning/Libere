# 当前验证：Libere 0.7.3（build 32）

199 项 XCTest、2215 项优化编译原生检查、18 项桥接测试和 Mac SDK 构建通过。随航 Pencil 书写、手指浏览、切换选择与空白取消选择已获用户实测确认，笔迹保存后可重新解码。新增 iCloud 下载状态、文件夹操作、Markdown 控件与公式回归，详见 [VALIDATION-0.7.3.md](VALIDATION-0.7.3.md)。下方保留历史版本记录；后续不再开发或验证原生 iPad 端。

# 验证记录 · Libere 0.7.1

2026-11-24，Apple Silicon Mac，Xcode 27.2，build 27。

- 133 项 XCTest、1636 项优化编译原生检查、18 项桥接测试通过；Mac、iPad Simulator、iPad device SDK 均构建成功。
- 8 项阅读入口检查覆盖AppStore统一入口、shared reader复用、无Mac sheet状态及打开前保存。Inspector按钮绑定和Mac旧sheet移除已逐项检查；隐藏SwiftUI窗口无可用AX按钮树，未声称自动点击了该按钮。
- 37 项折行检查覆盖100%/150%/200%真实文档宽高、TextKit折行增加、无横向溢出、Notebook工具栏不缩放、原生编辑器/undoManager复用、选区、IME和原生pinch结束。
- 23 项单元编辑器身份检查覆盖插入、删除别格、移动、清输出、legacy首次结构undo、Markdown与代码末格Shift+Enter。检查实际NSTextView及undoManager对象、原生undo/redo结果，并保留删除/转换/恢复后旧回调拒绝保护。
- NotebookOperationsTests 6项通过；新增历史快照检查证明保留运行时cellID且不修改尚未编辑的live JSON。

证据：.build/validation/check-0.7.1.log、native-0.7.1.log、reader-reflow-native.log、notebook-identity-native.log。新独立入口InspectorReaderNativeChecks、ReaderReflowNativeChecks、NotebookEditorIdentityNativeChecks已纳入总回归。

全部测试使用独立合成文件。未改动用户资料、未重启或替换系统中正在运行的应用。原生回归不等于实际设备手势手感验收；目录书签、真实loopback和iCloud双设备仍未实测。安装包采用本地临时签名，未Apple发行签名或公证。
