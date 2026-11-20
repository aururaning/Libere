#!/usr/bin/env python3
"""libere MCP stdio bridge. Python 3.9+, standard library only.
Protocol: initialize-based MCP 2025-11-25 / 2025-06-18.
No logs or secrets are written to stdout; stdout contains JSON-RPC only.
"""
import base64
import copy
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

VERSIONS = ['2025-11-25', '2025-06-18']
WRITES = {'create_page', 'append_blocks', 'update_block', 'layout_blocks'}
MAX_FILE = 64 * 1024 * 1024
RULES_URI = 'libere://agent-rules'
INSTRUCTIONS = ('先阅读 libere://agent-rules，搜索现有页面，再归档。正文用 Markdown，主要附件展开、补充资料收起；'
                '优先引用。修改前读取 revision；默认追加，重排先 dryRun。不得移动手写、锁定或关联批注。'
                '写入超时重试沿用同一 requestID，版本冲突先重新读取。')

class APIError(Exception):
    def __init__(self, code, message, status=0):
        super().__init__(message)
        self.code, self.status = code, status
    def value(self):
        return {'code': self.code, 'message': str(self), 'status': self.status}

class RPCError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code, self.data = code, data

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise APIError('redirect_refused', '本机接口不应重定向；请核对 libere 地址。', code)

class Client:
    def __init__(self, endpoint=None, token=None):
        value = endpoint or os.environ.get('LIBERE_AGENT_URL', 'http://127.0.0.1:19876')
        url = urllib.parse.urlsplit(value)
        try:
            port = url.port
        except ValueError as exc:
            raise APIError('invalid_url', '本机端口无效。') from exc
        if (url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost') or
                url.username or url.password or url.query or url.fragment or url.path not in ('', '/') or
                port is None or not 1024 <= port <= 65535):
            raise APIError('invalid_url', 'LIBERE_AGENT_URL 必须是 http://127.0.0.1:端口。')
        # Canonical numeric address avoids DNS and the IPv6 localhost ambiguity.
        self.endpoint = 'http://127.0.0.1:' + str(port)
        self.token = token if token is not None else os.environ.get('LIBERE_AGENT_TOKEN', '')
        if len(self.token) < 32 or any(ord(c) < 33 or ord(c) > 126 for c in self.token):
            raise APIError('missing_token', '请从 libere 的 Agent 接入窗口复制访问令牌。')
        self.workspace_id = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, payload=None, text=False):
        data = None if payload is None else json.dumps(payload, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
        headers = {'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'}
        for attempt in range(2):
            try:
                req = urllib.request.Request(self.endpoint + path, data=data, headers=headers)
                with self.opener.open(req, timeout=35) as response:
                    raw = response.read(100 * 1024 * 1024 + 1)
                    if len(raw) > 100 * 1024 * 1024:
                        raise APIError('response_too_large', '接口响应过大。')
                    return raw.decode('utf-8') if text else json.loads(raw)
            except urllib.error.HTTPError as exc:
                try:
                    error = json.loads(exc.read(16384)).get('error', {})
                except (ValueError, UnicodeError):
                    error = {}
                raise APIError(error.get('code', 'http_error'), error.get('message', 'libere 返回 HTTP ' + str(exc.code)), exc.code) from exc
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
                if attempt == 1:
                    raise APIError('connection_failed', '无法连接 libere；确认应用已打开、Agent API 已开启。若为写入超时，请沿用本次 requestID 核查。') from exc
        raise AssertionError('unreachable')

    def status(self):
        status = self.request('/v1/status')
        current = status.get('workspaceID')
        if not isinstance(current, str) or not current:
            raise APIError('invalid_status', '接口没有返回资料库身份。')
        if self.workspace_id is None:
            self.workspace_id = current
        elif current != self.workspace_id:
            raise APIError('workspace_changed', 'libere 已切换资料库；请重新连接 MCP 后选择归档位置。', 409)
        return status

    def tools(self):
        status = self.status()
        tools = copy.deepcopy(self.request('/v1/tools')['tools'])
        for item in tools:
            if item['name'] in WRITES:
                item['inputSchema']['properties']['requestID'] = {
                    'type': 'string', 'minLength': 8, 'maxLength': 128,
                    'description': '可省略由桥接器生成；手动重试同一写入时沿用原 ID，不能用于不同参数。'}
        if status.get('allowWrites'):
            tools.append({'name': 'import_file', 'description': '把当前资料库内已有文件的索引追加到页面，不上传或复制原文件。',
                'inputSchema': {'type': 'object', 'additionalProperties': False, 'required': ['pageID', 'expectedRevision', 'path'], 'properties': {
                    'pageID': {'type': 'string', 'format': 'uuid'}, 'expectedRevision': {'type': 'string', 'format': 'uuid'},
                    'path': {'type': 'string', 'description': '当前资料库内原文件的相对路径或绝对路径。'},
                    'collapsed': {'type': 'boolean', 'default': True}, 'sourceURL': {'type': 'string'},
                    'requestID': {'type': 'string', 'minLength': 8, 'maxLength': 128}}},
                'annotations': {'readOnlyHint': False, 'destructiveHint': False, 'openWorldHint': False}})
        return tools

    def call(self, name, arguments):
        arguments = dict(arguments)
        request_id = arguments.pop('requestID', None)
        if name == 'import_file':
            raw_path = arguments.pop('path', '')
            status = self.status()
            library = status.get('libraryPath')
            if not isinstance(raw_path, str) or not raw_path or not library:
                raise APIError('invalid_path', '需要当前资料库内已有文件的路径。')
            root = Path(library).resolve()
            path = (root / raw_path).resolve()
            try:
                relative = path.relative_to(root)
                if not path.is_file():
                    raise APIError('invalid_file', '找不到原文件，请先手动把文件放入资料库。')
            except ValueError as exc:
                raise APIError('outside_library', '只允许索引当前资料库内的文件。') from exc
            except OSError as exc:
                raise APIError('file_unreadable', '无法读取指定文件。') from exc
            block = {'kind': 'file', 'filePath': relative.as_posix(), 'collapsed': arguments.pop('collapsed', True)}
            if 'sourceURL' in arguments:
                block['sourceURL'] = arguments.pop('sourceURL')
            name = 'append_blocks'
            arguments['blocks'] = [block]
        self.status()
        writing = name in WRITES and not (name == 'layout_blocks' and arguments.get('dryRun', True))
        envelope = {'tool': name, 'arguments': arguments, 'workspaceID': self.workspace_id}
        if writing:
            request_id = request_id or str(uuid.uuid4())
            envelope['requestID'] = request_id
        try:
            return self.request('/v1/call', envelope)
        except APIError as exc:
            if writing:
                raise APIError(exc.code, str(exc) + ' requestID=' + request_id, exc.status) from exc
            raise

class Bridge:
    def __init__(self, client=None):
        self.client = client
        self.initialized = False

    def connection(self):
        if self.client is None:
            self.client = Client()
        return self.client

    def dispatch(self, message):
        if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
            raise RPCError(-32600, 'Invalid JSON-RPC request')
        method = message['method']
        if 'id' not in message:
            return None
        params = message.get('params', {})
        if not isinstance(params, dict):
            raise RPCError(-32602, 'params must be an object')
        if method == 'server/discover':
            raise RPCError(-32022, 'Use the initialize-based MCP protocol.', {'supportedVersions': VERSIONS, 'requestedVersion': params.get('_meta', {}).get('io.modelcontextprotocol/protocolVersion')})
        if method == 'initialize':
            self.connection().status()
            self.initialized = True
            return {'protocolVersion': params.get('protocolVersion') if params.get('protocolVersion') in VERSIONS else VERSIONS[0],
                    'capabilities': {'tools': {}, 'resources': {}}, 'serverInfo': {'name': 'libere', 'version': '0.6.2'}, 'instructions': INSTRUCTIONS}
        if method == 'ping':
            return {}
        if not self.initialized:
            raise RPCError(-32000, 'Initialize first')
        if method == 'tools/list':
            return {'tools': self.connection().tools()}
        if method == 'resources/list':
            return {'resources': [{'uri': RULES_URI, 'name': 'libere 归档与排版规范', 'mimeType': 'text/markdown'}]}
        if method == 'resources/read':
            if params.get('uri') != RULES_URI:
                raise RPCError(-32602, 'Unknown resource')
            return {'contents': [{'uri': RULES_URI, 'mimeType': 'text/markdown', 'text': self.connection().request('/v1/rules', text=True)}]}
        if method == 'tools/call':
            name, args = params.get('name'), params.get('arguments', {})
            if not isinstance(name, str) or not isinstance(args, dict):
                raise RPCError(-32602, 'name and arguments are required')
            if name not in {'list_pages', 'read_page', 'read_attachment', 'import_file'} | WRITES:
                raise RPCError(-32602, 'Unknown tool')
            try:
                value = self.connection().call(name, args)
                return {'content': [{'type': 'text', 'text': json.dumps(value, ensure_ascii=False)}], 'structuredContent': value, 'isError': False}
            except APIError as exc:
                return {'content': [{'type': 'text', 'text': json.dumps({'error': exc.value()}, ensure_ascii=False)}], 'isError': True}
        raise RPCError(-32601, 'Method not found')

    def process(self, line):
        message = None
        try:
            try:
                message = json.loads(line)
            except (ValueError, UnicodeError):
                raise RPCError(-32700, 'Parse error')
            result = self.dispatch(message)
            if result is None:
                return None
            return {'jsonrpc': '2.0', 'id': message['id'], 'result': result}
        except RPCError as exc:
            error = {'code': exc.code, 'message': str(exc)}
            if exc.data is not None:
                error['data'] = exc.data
        except APIError as exc:
            error = {'code': -32000, 'message': str(exc), 'data': exc.value()}
        except Exception:
            error = {'code': -32603, 'message': 'libere bridge could not process this request.'}
        return {'jsonrpc': '2.0', 'id': message.get('id') if isinstance(message, dict) else None, 'error': error}

def main():
    bridge = Bridge()
    # Serial calls preserve revision order. The app processes each write atomically;
    # cancellation notifications cannot undo an already committed write (use app Undo).
    for line in sys.stdin.buffer:
        response = bridge.process(line)
        if response is not None:
            print(json.dumps(response, ensure_ascii=False, separators=(',', ':'), allow_nan=False), flush=True)

if __name__ == '__main__':
    main()
