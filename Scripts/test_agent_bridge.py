import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
import sys
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('libere_agent', ROOT/'Sources/MarginNotes/Resources/libere_agent.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class FakeClient(m.Client):
    def __init__(self):
        super().__init__(token='a'*64)
        self.current='workspace-A'; self.writes=True; self.calls=[]; self.error=None
    def request(self,path,payload=None,text=False):
        self.calls.append((path,payload))
        if path=='/v1/status': return {'workspaceID':self.current,'allowWrites':self.writes}
        if path=='/v1/tools':
            tools=json.loads((ROOT/'Sources/MarginNotes/Resources/agent_tools.json').read_text())
            return {'tools':[t for t in tools if self.writes or t['name'] not in m.WRITES]}
        if path=='/v1/rules': return '# 规范'
        if self.error: raise self.error
        return {'requestID':payload.get('requestID'),'page':{'id':'fixture'},'arguments':payload['arguments']}

class BridgeTests(unittest.TestCase):
    def setUp(self): self.client=FakeClient(); self.bridge=m.Bridge(self.client)
    def rpc(self,method,params=None,id=1):
        return self.bridge.process(json.dumps({'jsonrpc':'2.0','id':id,'method':method,'params':params or {}}))
    def initialize(self): return self.rpc('initialize',{'protocolVersion':'2025-11-25'})
    def test_initialize_negotiates_supported_version(self):
        r=self.initialize()['result']; self.assertEqual(r['protocolVersion'],'2025-11-25'); self.assertIn('tools',r['capabilities'])
        self.assertEqual(self.rpc('initialize',{'protocolVersion':'unknown'})['result']['protocolVersion'],'2025-11-25')
    def test_modern_probe_gives_explicit_fallback(self):
        r=self.rpc('server/discover',{'_meta':{'io.modelcontextprotocol/protocolVersion':'2026-07-28'}})
        self.assertEqual(r['error']['code'],-32022); self.assertIn('2025-11-25',r['error']['data']['supportedVersions'])
    def test_needs_initialize(self): self.assertIn('error',self.rpc('tools/list'))
    def test_tool_catalog_adds_import_and_retry_field(self):
        self.initialize(); tools=self.rpc('tools/list')['result']['tools']
        self.assertEqual(len(tools),8); self.assertEqual(tools[-1]['name'],'import_file')
        self.assertIn('requestID',next(t for t in tools if t['name']=='append_blocks')['inputSchema']['properties'])
    def test_read_only_catalog(self):
        self.client.writes=False; self.initialize()
        self.assertEqual(len(self.rpc('tools/list')['result']['tools']),3)
    def test_workspace_is_pinned(self):
        self.initialize(); self.client.current='workspace-B'
        result=self.rpc('tools/call',{'name':'create_page','arguments':{'title':'错位'}})['result']
        self.assertTrue(result['isError']); self.assertIn('workspace_changed',result['content'][0]['text'])
        self.assertFalse(any(p=='/v1/call' for p,_ in self.client.calls))
    def test_write_uses_stable_explicit_request_id(self):
        args={'title':'归档','requestID':'same-request'}
        a=self.client.call('create_page',args); b=self.client.call('create_page',args)
        self.assertEqual(a,b); self.assertEqual(a['requestID'],'same-request'); self.assertNotIn('requestID',a['arguments'])
        self.assertIn('requestID',args)
    def test_write_generates_request_id_and_read_does_not(self):
        a=self.client.call('create_page',{'title':'归档'}); self.assertTrue(a['requestID'])
        b=self.client.call('read_page',{'pageID':'id'}); self.assertIsNone(b['requestID'])
    def test_dry_layout_does_not_mutate(self):
        self.assertIsNone(self.client.call('layout_blocks',{})['requestID'])
        self.assertTrue(self.client.call('layout_blocks',{'dryRun':False})['requestID'])
    def test_import_preserves_bytes_and_title(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'中文.md'; data=b'# text\r\n'+ '🍎'.encode(); path.write_bytes(data)
            value=self.client.call('import_file',{'path':str(path),'pageID':'p','expectedRevision':'r','collapsed':False})
            block=value['arguments']['blocks'][0]
            self.assertEqual(m.base64.b64decode(block['dataBase64']),data); self.assertEqual(block['filename'],'中文.md'); self.assertFalse(block['collapsed'])
    def test_import_rejects_relative_or_empty(self):
        with self.assertRaises(m.APIError): self.client.call('import_file',{'path':'relative.md'})
        with tempfile.NamedTemporaryFile() as file:
            with self.assertRaises(m.APIError): self.client.call('import_file',{'path':file.name})
    def test_error_is_tool_result_and_keeps_retry_id(self):
        self.initialize(); self.client.error=m.APIError('revision_conflict','页面已变化',409)
        result=self.rpc('tools/call',{'name':'append_blocks','arguments':{'requestID':'retry-1234'}})['result']
        self.assertTrue(result['isError']); self.assertIn('retry-1234',result['content'][0]['text'])
    def test_resource_returns_norms(self):
        self.initialize(); self.assertEqual(self.rpc('resources/read',{'uri':m.RULES_URI})['result']['contents'][0]['text'],'# 规范')
        self.assertIn('error',self.rpc('resources/read',{'uri':'file:///etc/passwd'}))
    def test_invalid_json_and_notifications(self):
        self.assertEqual(self.bridge.process('{')['error']['code'],-32700)
        self.assertEqual(self.bridge.process('[]')['error']['code'],-32600)
        self.assertIsNone(self.bridge.process('{"jsonrpc":"2.0","method":"notifications/initialized"}'))
    def test_endpoint_and_token_constraints(self):
        for url in ['https://127.0.0.1:19876','http://example.com:19876','http://user@localhost:19876','http://localhost:19876/x','http://127.0.0.1:19876?token=x']:
            with self.assertRaises(m.APIError): m.Client(endpoint=url,token='a'*64)
        with self.assertRaises(m.APIError): m.Client(token='')
        self.assertEqual(m.Client(endpoint='http://localhost:19876/',token='a'*64).endpoint,'http://127.0.0.1:19876')
    def test_redirect_never_forwards_token(self):
        with self.assertRaises(m.APIError): m.NoRedirect().redirect_request(None,None,302,'',{},'https://example.com')
    def test_network_retry_reuses_identical_request(self):
        class Opener:
            def __init__(self): self.data=[]
            def open(self,req,timeout):
                self.data.append(req.data)
                if len(self.data)==1: raise urllib.error.URLError('timeout')
                return io.BytesIO(b'{"ok":true}')
        client=m.Client(token='a'*64); client.opener=Opener()
        client.request('/v1/call',{'requestID':'one-logical-write','tool':'create_page','arguments':{'title':'text'}})
        self.assertEqual(client.opener.data[0],client.opener.data[1])
    def test_http_conflict_is_not_retried(self):
        class Opener:
            calls=0
            def open(self,req,timeout):
                self.calls+=1
                raise urllib.error.HTTPError(req.full_url,409,'conflict',{},io.BytesIO(b'{"error":{"code":"revision_conflict","message":"changed"}}'))
        client=m.Client(token='a'*64); client.opener=Opener()
        with self.assertRaises(m.APIError) as caught: client.request('/v1/call',{})
        self.assertEqual(caught.exception.code,'revision_conflict'); self.assertEqual(client.opener.calls,1)

if __name__=='__main__': unittest.main()
