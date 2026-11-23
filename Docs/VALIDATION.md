# 验证记录 · Libere 0.6.13

2026-11-23，Apple Silicon Mac，Xcode 27.2，build 25。

- XCTest：109 项通过；Agent 桥接：18 项通过；工程结构57个Swift源文件。Mac/iPad Simulator/iPad device SDK 构建通过。
- 原生回归：1430 项通过，包含32项选中框全选/Unicode/五档缩放顶部三行命中/迟到请求取消、46项iCloud访问与下载/释放安全检查；编辑时改用外侧拖柄，边缘让给文字选择。
- Markdown13、Formula10、PageLink3项专项通过。8个实际WebKit公式布局和3个mtext空白宽度案例通过，截图已目视。可重复脚本 Scripts/MathRenderChecks.swift。
- iCloud检查用注入操作验证7天边界、首次登记无全库文件读取、分批上限、开关、上传/冲突/编辑保护、两次检查间新增内核保护、关闭时重新计时、重启账本、显式下载成功/失败；另验证真实非iCloud文件绝不释放。未调用删除原件API。

原生日志 .build/validation/native-0.6.13-debug.log 与 native-0.6.13-final.log；SDK/XCTest日志 check-0.6.13-final.log。公式渲染证据 math-render.json/png/log。真实iCloud账号和设备交互未实测；目录书签、真实loopback通信保持明确跳过，不计入通过数量。未修改或重启用户当前应用，未对用户资料执行释放。
