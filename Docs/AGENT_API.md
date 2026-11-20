# libere Agent 接入

Libere 0.6.11 提供本机 HTTP API 和 MCP stdio 桥接器，让外部 agent 把结论、来源、文件保存到正在打开的资料库。资料仍使用已有页面、Markdown、原文件索引和引用模型；每次 agent 写入都进入画布撤销历史。

## 开始使用

1. 打开 `MacBuild/libere.app`，打开希望接收资料的资料库。
2. 选择菜单“笔记 → Agent 接入…”（侧栏齿轮也有入口），开启“本机 Agent API”。默认地址 `http://127.0.0.1:19876`，端口可改。
3. 点击“复制 MCP 配置”，粘贴到所用 agent 客户端的 MCP 服务器设置中。配置包含桥接脚本的实际路径和本机令牌；客户端需在同一台 Mac 上启动 `python3`（3.9 或更新）。脚本无第三方 Python 依赖。若客户端找不到 Python，将 command 改为本机 Python 的绝对路径。
4. 可以这样交代 agent：“把这次讨论的结论和原始资料归档到 libere 的某项目，先查找已有页面；主要 PDF 展开，参考资料收起；保留来源链接。”
5. 用“复制排版与操作规范”取得完整规范，也可让 MCP 读取 `libere://agent-rules`。工具输出包含页面路径和 ID，可在侧栏找到。

开启状态、端口、令牌和读写开关会记住。关闭开关停止接入；重新生成令牌使旧配置失效，需要重新复制。切换资料库时服务切换到新资料库，已连接桥接器仍绑定旧 workspaceID，因此会提示重新连接，不会静默写错位置。应用退出后接口关闭。应用挪动位置后请重新复制配置，以更新桥接脚本路径。

## 归档和展示约定

完整规范：[agent_rules.md](../Sources/MarginNotes/Resources/agent_rules.md)。建议正文用 Markdown 分成“结论、依据、步骤/待办、来源”；附件按阅读重要性排序，原始资料与摘要并存。已有文件用引用，避免反复上传。

| 选项 | 行为 |
| --- | --- |
| `reading` | 默认；宽页正文左、资料右，同类按输入顺序；窄页单列 |
| `column` | 全部块按给定顺序单列，适合文字与附件交错 |
| `grid` | 从左到右、从上到下，按每行最高块预留间距 |
| `collapsed:true` | 文件/链接/引用只显示 36 点高标题行，保留图标及路径，默认值 |
| `collapsed:false` | 展开预览；可用 `height` 指定初始预览高度，默认 480 点 |
| `sourceURL` | 记录来源网址，可在块右键菜单打开 |

块标题栏右侧箭头随时切换收起与展开，展开恢复原预览高度。过窄时优先保留文件名尾部。已锁定的块先在应用内解锁。文件只登记资料库内路径；编辑器直接保存原文件，不生成附件或工作镜像。

追加内容放在现有内容和手写下方，不重新移动既有块。整理既有块先 dryRun；有画布手写的页面不自动重排，带锁定/关联批注/页内批注的块也受保护。选定块的排序位置在未选定内容之后。API 不执行 Notebook、不修改文件正文、不删除页面；本版集中实现资料归档和布局。

## HTTP

所有请求（包括状态和规范）携带 `Authorization: Bearer <令牌>`。`POST` 使用 `Content-Type: application/json` 与 `Content-Length`；常见 HTTP 客户端自动设置长度。本接口不是 MCP 的 Streamable HTTP 地址；MCP 请使用上面的 stdio 配置。

| 接口 | 返回 |
| --- | --- |
| `GET /v1/status` | API 版本、资料库名称、workspaceID、读写状态和大小限制 |
| `GET /v1/tools` | 当前可用工具与 JSON Schema；只读模式隐藏写入工具 |
| `GET /v1/rules` | Markdown 操作规范 |
| `GET /v1/openapi.json` | OpenAPI 3.1 文档 |
| `POST /v1/call` | 调用下表工具 |

| 工具 | 主要参数和用途 |
| --- | --- |
| `list_pages` | `query`、`parentID`、`offset`、`limit`；查找页面/文件夹 |
| `read_page` | `pageID`；读取正文、revision、块 ID、展示状态与引用 |
| `read_attachment` | `pageID`、`blockID`；`format` 为 metadata / text / base64，text 支持字符 offset/limit |
| `create_page` | `title`、可选 parentID/isFolder/canvasWidth/blocks/style |
| `append_blocks` | `pageID`、`expectedRevision`、`blocks`、可选 style |
| `update_block` | `pageID`、`blockID`、`expectedRevision`；text/sourceURL/collapsed 至少一个 |
| `layout_blocks` | `pageID`、`expectedRevision`、可选 blockIDs/style；`dryRun` 默认 true |
| `import_file`（MCP 专有） | `pageID`、`expectedRevision`、资料库内相对或绝对 path、可选 collapsed/sourceURL；桥接为 append_blocks，仅传路径 |

HTTP 调用外层格式：

```json
{
  "tool": "create_page",
  "workspaceID": "从 status 取得",
  "requestID": "本次逻辑写入的 UUID",
  "arguments": {
    "title": "主题研究：结论与资料",
    "style": "reading",
    "blocks": [
      {"kind": "text", "text": "# 研究结论\n\n记录结论、依据和下一步。", "sourceURL": "https://example.com/research"},
      {"kind": "link", "url": "https://example.com/research", "filename": "原始来源", "collapsed": true}
    ]
  }
}
```

`blocks.kind` 可为 `text`、`formula`、`file`、`reference`、`link`。`file` 需填写 `filePath`，为当前资料库内已有文件的相对路径；禁止路径穿越、符号链接越界和索引内部控制文件。旧 `attachment` 名称仅兼容带 filePath 的请求，dataBase64 上传被拒绝。引用使用 sourcePageID/sourceBlockID；公式 text 为 LaTeX，普通 text 为 Markdown。MCP import_file 只核对位置并转发路径，不读取/上传整份文件。

下面是可直接改用的 Python 标准库示例。先在环境变量中设置从应用复制的令牌，然后运行：

```python
import json, os, urllib.request, uuid
base = os.environ.get("LIBERE_AGENT_URL", "http://127.0.0.1:19876")
headers = {"Authorization": "Bearer " + os.environ["LIBERE_AGENT_TOKEN"],
           "Content-Type": "application/json"}
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def request(path, payload=None):
    body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode()
    with opener.open(urllib.request.Request(base + path, data=body, headers=headers), timeout=35) as reply:
        return json.load(reply)
workspace = request("/v1/status")["workspaceID"]
# 保存 envelope；网络失败后重试必须复用它，不能重新生成 requestID。
envelope = {"tool": "create_page", "workspaceID": workspace, "requestID": str(uuid.uuid4()),
            "arguments": {"title": "对话归档", "blocks": [{"kind": "text", "text": "## 结论\n\n我的记录。"}]}}
result = request("/v1/call", envelope)
print(result["page"]["path"], result["page"]["id"])
```

修改已有页前先 read_page，随后把返回的 revision 作为 expectedRevision。成功写入返回新 revision、page 摘要和 changedBlocks；用 read_page 读取最终完整正文。MCP 自动处理 workspaceID；requestID 可省略自动生成，也可手动指定以跨调用复用。

## 一致性与限制

一次写入先验证整批内容，再落盘和发布；非法附件/无空间时不会插入半批。索引与批注进入导出/同步体系，原文件由用户保存的资料库文件夹承载；所有编辑器先保存，避免 agent 越过未提交的正文。相同相对路径复用文件身份，同批重复索引也共享一份原文件。

最近 256 笔写入回执持久保存，重试返回同一结果；同一 requestID 携带不同参数返回 409。撤销以后重试旧 requestID 仍只返回回执，不重新应用。修改内容产生 revision_conflict 时先重读再决定，用新 ID；禁止盲目重试覆盖用户修改。更早的历史任务重试前先检查页面。

单次最多 50 块、每块 100000 字符、单次文件读取最多 64 MiB，请求体最多 96 MiB。支持 PDF、图片（PNG/JPEG/HEIC/HEIF/GIF/TIFF/BMP/WebP）、Markdown、Notebook、HTML 和现有文本/源代码类型。图片原件可用 metadata/base64 读取，text 返回 image_not_text；GIF/TIFF 预览首帧。大批归档分批执行，每批使用最新 revision。引用批注独立，跨页文字来源不自动变成引用。

目前 MCP 声明兼容 initialize 流程的 2025-11-25、2025-06-18 协议。收到现代 server/discover 探测时返回明确的版本不支持及兼容版本列表，供客户端回退；仅支持 2026 协议、没有 initialize 回退的客户端需要通过 HTTP API 接入。规范依据：[stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[工具](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。

服务仅绑定 127.0.0.1；有令牌才能访问，拒绝带浏览器 Origin 的请求，无公网监听。只有用户在应用中开启才启动。只读开关关闭全部写入；重新生成令牌会撤销旧连接。令牌存在本机应用设置中，属于访问凭据，不应提交到仓库或贴入笔记。MCP 的取消通知不撤销已经提交的原子写入，恢复请用画布撤销。

本轮实际网络请求被执行环境以 Operation not permitted 拒绝，没有更换通道重试；已通过的数据层和模拟客户端测试不等同于真实外部 agent 连通验收。原生端到端用例保留，可在允许本机网络的 Mac 终端运行 `bash Scripts/check-native.sh --test-agent-transport`，覆盖 HTTP 认证、Origin 拒绝、MCP 握手、工具发现、保存正文与规范读取。未替用户配置某个尚未指定的第三方客户端。
