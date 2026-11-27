# Mac 随航、触摸与 Pencil

当前范围：Libere 0.7.2 build32，2026-11-27。只维护 Mac 应用，iPad 用作随航屏幕和 Pencil 输入设备；不再开发原生 iPad 端。

## 使用

把 Mac 的 Libere 窗口移到 iPad 随航屏幕。在「手写」模式用 Pencil 落笔，用手指滑动浏览；切回「选择」后，点内容块可切换选择，点空白取消选择。手写模式不再显示底部常驻提示。

画笔、荧光笔、整笔橡皮、粗细和颜色均可设置。笔迹以 PencilKit 的 PKDrawing 保存，和内容块布局独立，不参与吸附或自动排版。

## 输入路径

- MacInk 只接收明确的 tablet point 事件或鼠标事件的 tablet point 子类型。不能只看压力，因为触控板也有压力输入；proximity 属性只在对应事件类型中读取。
- 纯 tablet 事件可开始、更新和结束笔画；兼容带 tablet 子类型的鼠标按下/拖动/抬起。笔识别器不接受手指直接触摸，也不由滚动识别器取消。
- CanvasViewport 的独立直接触摸点击识别器处理手指点选，允许手指平移取消点击；它与鼠标/Pencil 路由分开。CanvasPointer 切换内容块或清除空白选择时清除过时的捕获状态，保留活动编辑器和链接的原生操作。
- macOS 27 路径使用非排他的触摸策略，保留祖先滚动视图的浏览手势。较早系统按可用 API 运行，不虚构直接触摸能力。
- 落笔期间暂时关闭 NSEvent 鼠标事件合并，完成/取消后恢复；不指定或承诺硬件采样率。笔迹使用 PencilKit 插值点绘制，已提交笔画缓存几何形状。

## 本轮验收

用户在独立测试应用中确认 Pencil 书写、手指浏览、点 A/B 切换与点空白取消选择「全部正常」。保存的绘图在测试应用重开后解码为23笔、1098点、29170字节。输入记录中的7次点击全部被处理，包含A、B和空白切换。

自动回归包含笔事件分类、纯 tablet 生命周期、直接触摸与滚动分流。原始笔迹和输入日志只保留本地；LIBERE_INPUT_TRACE 仅编入隔离测试程序，正式二进制不包含它。更完整的证据与范围见 [VALIDATION-0.7.2.md](VALIDATION-0.7.2.md)。

悬停、双击换工具、Pencil Pro 捏合及 Mac 完整套索仍未接入。其他硬件组合和所有缩放倍率不在本轮设备验收范围。

## Apple 参考

- [TN3212：随航触摸适配](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support)
- [NSGestureRecognizer.allowedTouchTypes](https://developer.apple.com/documentation/appkit/nsgesturerecognizer/allowedtouchtypes)
- [NSEvent.pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure)
- [Apple 随航使用说明](https://support.apple.com/102597)
- [Apple 事件合并说明](https://developer.apple.com/documentation/appkit/nsevent/ismousecoalescingenabled)
- [WWDC：检查和修改 PencilKit 绘图](https://developer.apple.com/videos/play/wwdc2020/10148/)
