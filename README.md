# Libere

Libere 是面向 Mac 和 iPad 的原生知识笔记应用。将文字、公式、PDF、图片、网页和代码放到同一张自由画布上，从阅读资料到整理思路，再到写作和项目推进。

当前版本：**0.6.9（build 21）**。源码以 **PolyForm Noncommercial 1.0.0** 公开（source-available），适用非商业许可。具体授权范围见 [LICENSE](LICENSE)，声明见 [NOTICE](NOTICE)。

## 可以做什么

- **自由画布**：内容块可移动、缩放、折叠和展开；支持选择、撤销、回收站与文件夹层级。
- **文字与公式**：Markdown 编辑与预览、公式排版、原生文字编辑器和中文输入。
- **资料阅读与批注**：PDF 翻页，图片和长文档预览，页内文字与手写批注，以及资料旁的文字分支。
- **文件编辑**：Markdown、HTML、源码和 Jupyter Notebook；Mac 可连接本机 Python 环境执行 Notebook。
- **文件夹首页**：编辑介绍、分类标题和列表，插入子页面链接组成目录。
- **资料归档**：保留导入原件，重复使用附件引用；完整备份、本地保存和可选 CloudKit 同步。
- **Agent 接入**：通过本机 HTTP API 或 MCP stdio 桥接器查找页面、归档内容和整理布局，由用户主动启用。

内置四组可编辑场景：课堂笔记、论文思路与写作、代码库管理、项目管理。共 13 个示例页面，可从“笔记 → 场景展示”进入。

## 开始使用

运行系统：**macOS 14+** 或 **iPadOS 17+**。Mac 本地构建按当前机器架构生成；本项目的已有 Mac 验证使用 Apple Silicon。

在 Mac 安装完整 Xcode 和 Python 3 后，从仓库根目录运行：

```bash
git clone https://github.com/aururaning/Libere.git
cd Libere
bash Scripts/run-mac.sh
```

脚本构建并打开 `.build/XcodeProducts/Debug/Libere.app`。首次启动选择资料库目录；以后可通过“存储位置…”切换。详细环境设置与 iPad 构建见 [构建说明](Docs/BUILD.md)。

若需要生成 Mac 安装包：

```bash
bash Scripts/build-mac-package.sh
```

生成文件位于 `dist/`。已发布的安装包以仓库 [Releases](https://github.com/aururaning/Libere/releases) 页面为准。

## 常用操作

- 单击选择内容块；双击或点击“编辑”输入文字。编辑时也可使用框外拖柄移动。
- 点击空白或另一个块结束当前编辑；选中块后按 Delete 删除，⌘Z 撤销。
- 展开附件后可滚动查看内容；最近展开的附件显示在更上层。
- 阅读器的文字批注通过双击页面空白处添加；手写与文字批注分层保存。
- 文件夹首页点击“编辑介绍”，添加文字、分类和子页面目录。

完整规则见 [交互说明](Docs/INTERACTION.md)。

## 文档与开发

- [构建、测试与打包](Docs/BUILD.md)
- [验证范围与已知限制](Docs/VALIDATION.md)
- [Agent API / MCP 接入](Docs/AGENT_API.md)
- [CloudKit 配置](Docs/ICLOUD.md)
- [随航与手写输入](Docs/SIDECAR.md)
- [参与贡献](CONTRIBUTING.md) · [安全反馈](SECURITY.md) · [版本变化](CHANGELOG.md)

项目没有第三方 Swift 包依赖。Notebook 执行另需本机 Python 环境中的 `jupyter_client` 和 `ipykernel`；阅读已保存的 Notebook 不要求启动内核。

当前本地构建使用临时签名，尚未完成 Apple 发行签名和公证。iPad 实机、随航手感和 CloudKit 多设备行为需要对应硬件与账号验证；自动化检查的范围见验证文档。
