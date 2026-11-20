# 随航、触摸与 Pencil API

核对日期：2026-11-18。Apple 的 TN3212 明确说明，macOS 27 与 iPadOS 27 的随航扩展直接触摸使用 AppKit 手势识别器。触摸不经过普通 responder 链、`sendEvent` 或本地/全局事件监听器。

| 使用场景 | API | 本项目的使用 |
| --- | --- | --- |
| iPad 原生手写 | `PKCanvasView`、`.drawingPolicy = .pencilOnly` | 默认只让 Pencil 落笔；手指浏览 |
| Mac 随航触摸 | `NSGestureRecognizer`、`allowedTouchTypes`、`NSScrollView` | 笔迹识别器不接收直接触摸，祖先滚动视图处理浏览 |
| Mac 数位笔 | `NSEvent` 的 tablet point 事件/子类型、`pressure` | 将数位笔位置与压力转为 `PKStrokePoint` |
| 跨平台手写数据 | `PKStrokePath`、`PKStroke`、`PKDrawing` | Mac 创建的笔画和 iPad 使用同一数据格式 |
| 新 SwiftUI 输入分类 | `GestureInputKinds.pencil`、`.directTouch`、`.indirectTouch`、`.pointer` | macOS/iPadOS 27 可用于后续统一 SwiftUI 手势过滤；当前画笔仍使用 AppKit/PencilKit |
| 滚动中止画笔 | `NSGestureRecognizer.isCancellableByScrollGesture` | macOS 27 上启用，并处理取消，不保存未结束笔画 |

不能只通过压力大小判断是否为 Pencil：触控板也有压力事件。`pointingDeviceType` 只适用于 proximity 事件或其对应子类型；不能随意读取所有鼠标事件的此属性。本实现先过滤 tablet point 事件。

## 手势结构

手写时，透明覆盖层只拦截笔迹；它的祖先保留页面滚动视图。选择模式关闭覆盖层命中，恢复下方文字和 PDF 的操作。Apple 明确提示：覆盖在标准控件上方的透明视图会阻挡下方同级控件的手势，因此不能依靠“透明”实现触摸穿透。

## 真机检查

1. 在 macOS 27 / iPadOS 27 连接随航，把 Mac App 移到 iPad，开启手写。
2. Pencil 写线条；抬笔后应保存，重新打开笔迹仍在，位置保持页面坐标。
3. 手指滑动应浏览页面，不产生笔迹；开始滚动时进行中的笔画可取消。
4. 在 35%、85%、150% 缩放下跨文字和 PDF 写字，检查落点一致。
5. 用画布撤销撤销最后一笔；通过备份或已配置的 iCloud 在 iPad 原生版打开，检查笔迹可由 PencilKit 编辑。
6. 切回选择模式，确认文字可编辑、PDF 可翻页、资料把手可操作。

## 官方来源

- [TN3212：随航触摸适配](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support)
- [SwiftUI GestureInputKinds](https://developer.apple.com/documentation/swiftui/gestureinputkinds)
- [NSGestureRecognizer.allowedTouchTypes](https://developer.apple.com/documentation/appkit/nsgesturerecognizer/allowedtouchtypes)
- [PencilKit pencilOnly](https://developer.apple.com/documentation/pencilkit/pkcanvasviewdrawingpolicy/pencilonly)
- [NSEvent.pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure)
- [Apple 随航使用说明](https://support.apple.com/102597)

原生矢量显示和笔画数据已有自动检查，真实随航手感仍需要按以上步骤在设备上复测。

Mac 新版在笔下期间设置 `NSEvent.isMouseCoalescingEnabled = false`，结束/取消恢复之前设置；不指定或虚构硬件采样率。采用 `PKStrokePath.interpolatedPoints(in:by:)` 显示连续 B-spline，缓存已提交的几何形状。压感笔、均匀线条、荧光笔、整笔橡皮及粗细/颜色均可设置。iPad 继续支持系统 PencilKit 工具栏。

新增参考：[Apple 事件合并说明](https://developer.apple.com/documentation/appkit/nsevent/ismousecoalescingenabled)、[WWDC：检查和修改 PencilKit 绘图](https://developer.apple.com/videos/play/wwdc2020/10148/)。

悬停、双击换工具、Pencil Pro 捏合及 Mac 完整套索仍未接入。
