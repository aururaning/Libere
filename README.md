<div align="center">

<img src="Sources/MarginNotes/Resources/BrandLogo.png" width="88" alt="Libere Logo" />

# Libere

**由 p 人打造的一款个人知识库管理软件！**

[![Version](https://img.shields.io/badge/version-0.7.3-2657c7?style=flat-square)](https://github.com/aururaning/Libere/releases/latest)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20(Apple%20Silicon)-111827?style=flat-square&logo=apple&logoColor=white)](https://github.com/aururaning/Libere/releases/latest)
[![Built With](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-F05138?style=flat-square&logo=swift&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial-4b5563?style=flat-square)](LICENSE)

[下载最新版本](https://github.com/aururaning/Libere/releases/latest) · [版本更新日志](CHANGELOG.md) · [操作说明](Docs/INTERACTION.md) · [源码构建](Docs/BUILD.md) · [Agent 接入](Docs/AGENT_API.md)

</div>

---

Libere 是一款面向 Mac 的自由画布笔记与知识库应用。支持 **PDF、Python 脚本、Jupyter Notebook、图片、HTML、网页链接和 Markdown（带离线公式）** 等各种格式——你可以把它们像便签和草稿纸一样在画布上任意排布、实时预览，还能直接在旁边做批注。

和传统笔记软件把文件全塞进私有数据库不同，**Libere 直接使用资料库里的原文件**：添加索引时只记录路径；粘贴库外文件或截图时，会一次性归档到当前页面文件夹并按类型分类，之后编辑直接使用归档原件，不创建工作镜像；你在侧栏重命名、拖动整理文件夹，磁盘上的原文件也会跟着一起移动。换设备或备份时，直接带走你的资料库文件夹就行，永远不会被软件锁死格式。

---

## 适用场景

| 场景 | 在 Libere 里怎么用 |
| --- | --- |
| **上课记笔记** | 把课堂讲义、课本 PDF、Slides 摊在同一张画布上，复习时不用在十几个窗口里切来切去！ |
| **读论文、写文章** | 论文原文、公式推导和页内/页外批注摆在一起，思路和参考资料一目了然！ |
| **代码开发** | 内置 Jupyter Notebook 执行环境与本地 Agent 接口，支持边写代码边让 Agent 帮你记录开发日志和整理目录。 |
| **整理项目** | 按文件夹收集需求文档、参考网页、会议记录和下一步计划，把零散文件串成项目主页。 |

> 软件内置了这四个场景的示例模板，从「笔记 → 示例场景」可手动打开修改。另有覆盖14组、57项功能的可搜索教程，首次使用会在右上角提示教程入口，覆盖升级不重复提示或插入示例页面。

---

## 核心功能

当前 **0.7.3 build 32** 修复 iCloud 下载状态、随航 Pencil 与手指触摸、Markdown 按钮和公式显示，并增加子文件夹入口。普通文字和普通块使用 `⌘C / ⌘X / ⌘V`，文件、页面和文件夹使用 `⌘C / ⌘V / ⌘⌥V`；移动同步更新原文件、引用和撤销记录。

- **自由画布 + 多级批注分支**：文字框（Markdown / 离线 LaTeX 公式）、PDF、代码文件、图片、网页和手写笔迹都能混排在一张纸上；支持多选框选、对齐分布，以及从任意资料引出带连线的批注分支。
- **库内原件直连**：目前支持本地文件夹与 **iCloud Drive**。库内文件通过“添加文件索引”直接使用原件；外部文件可粘贴后一次性归档。支持安全释放已上传、闲置的 iCloud 本地下载。
- **鼠标位置粘贴与分类归档**：复制一个或多个普通文件、截图或图片后，在画布上按 `⌘V`。库外内容按类型归档到当前页面文件夹，同名自动编号；应用内复制保留“前往原位置”入口。其他不能内嵌预览的格式以文件卡片显示，可用系统应用打开。
- **代码、网页与 Notebook 直接可用**：Markdown、Python、HTML 支持直接编辑保存；Jupyter Notebook 可连接本机 Python 内核直接运行单元格并保存输出；网页链接支持卡片 / 离线 HTML / 内嵌浏览器三种模式切换。
- **快速检索与双向跳转**：支持 `⌘K` 全文搜索页面、正文、公式、文件名、标签和页内批注；输入 `[[` 可快速插入页面引用，底部面板可查看标签与反向链接。
- **兼容 Agent 联动**：可在菜单栏 `笔记 → Agent 接入…` 开启本地 HTTP / MCP 服务，让外部 AI Agent 帮你查笔记、建索引、做排版。

---

## 下载与使用

- **系统要求**：**macOS 14 及以上**（当前安装包支持 **Apple Silicon / M 系列芯片**）
- **下载安装**：前往 [Release 页面](https://github.com/aururaning/Libere/releases/latest) 下载最新的 `.pkg` 安装包安装即可。
- **首次打开**：选择你用来存放笔记和资料的文件夹（本地目录或 iCloud Drive 均可）。库内文件可通过拖拽或“添加文件索引”加入画布；库外文件和截图也可以直接粘贴，自动归档到当前页面文件夹。

> **小提示**
> 1. 安装包目前是个人自签名、尚未经过苹果公证，首次打开如遇系统拦截，在「系统设置 → 隐私与安全性」点击 **仍要打开** 即可。
> 2. 后续只维护 Mac 版，iPad 可作为随航屏幕和 Pencil 输入设备；“导出索引与批注”只导出笔记结构与批注，不包含原文件本身，迁移资料库请直接移动整个资料库文件夹。

---

## 最近更新

最新版本为 **0.7.3（build 32）**，修复 iCloud 已下载却仍等待、随航笔与手指输入、Markdown 编辑/预览及常用公式，完善文件夹入口；保留鼠标位置粘贴、自动分类归档、来源索引和57项功能教程。**0.7.1** 解决了阅读窗口复用、代码放大折行和 Notebook 单格撤销等问题；**0.7.0** 版本新增了 `⌘K` 全局搜索、`[[` 双链、画布多选对齐、Finder 拖拽建索引和回收站清理等完整工作流。

👉 查看完整版本变化：[CHANGELOG.md](CHANGELOG.md) · [0.7.3 更新说明](Docs/RELEASE-0.7.3.md) · [0.7.2 更新说明](Docs/RELEASE-0.7.2.md) · [0.7.1 更新说明](Docs/RELEASE-0.7.1.md) · [0.7.0 更新说明](Docs/RELEASE-0.7.0.md)

---

## 反馈与参与

遇到 Bug、有想要的新功能，或者对使用方式有疑问，欢迎直接来 [Issues](https://github.com/aururaning/Libere/issues) 留言！

## 许可

本项目源码采用 [PolyForm 非商业许可证](LICENSE) 公开，仅限非商业用途。具体条款见 [LICENSE](LICENSE)。
