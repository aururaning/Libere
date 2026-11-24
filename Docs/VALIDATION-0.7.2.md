# Libere 0.7.2 验证

2026-11-24。160 XCTest、1796优化编译原生断言、18桥接测试通过，Mac/iPad Simulator/iPad device三个SDK构建成功。

新增覆盖：剪贴板NSURL/旧文件列表/原始图片与PDF数据；鼠标纸面坐标与0.5x/1x/1.5x/2x原生缩放；库内复用、库外一次归档、原件保留、同名冲突、后台切页与改名；同组撤销/重做；来源页面与块定位；文件主件和伴随目录的事务、精确路径撤销及失败恢复。教程覆盖14组56项、搜索、真实原生搜索框和滚动正文、宽窄布局、首次使用、旧库升级不显示、手动打开且不改资料库。

证据：.build/validation/check-0.7.2.log、native-0.7.2.log、clipboard-archive-xctest.log、feature-guide-native.log、feature-guide-1100.png、feature-guide-720.png。中间两处回归脚本假设已修正：保存后的JSON字节比较时点；允许类型改为通用data后用类型继承验证PNG/JPEG仍可选。最终完整原生回归通过。

本轮所有功能测试使用隔离合成资料；没有操作用户资料库，未重启或替换/Applications中的运行应用。真实跨设备iCloud和live HTTP/MCP尚未实测；截图来自自建测试窗口。安装包未Apple公证。
