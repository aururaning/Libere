#!/usr/bin/env python3
"""Generate the public HTTP tool catalog and OpenAPI from one schema source."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Sources/MarginNotes/Resources'
def string(**kw): return {'type':'string', **kw}
def obj(properties, required=()): return {'type':'object','properties':properties,'required':list(required),'additionalProperties':False}
uid = string(format='uuid')
revision = {'pageID':uid,'expectedRevision':uid}
style = string(enum=['reading','column','grid'],default='reading',description='reading：宽页正文+资料侧栏，窄页单列；column：顺序单列；grid：网格。')
source = string(format='uri',description='原始资料的 http(s) 来源，仅记录，不自动访问。')
block = obj({'kind':string(enum=['text','formula','attachment','reference','link']),
 'text':string(maxLength=100000,description='文字为 Markdown；公式为 LaTeX。'),
 'filename':string(maxLength=240),'dataBase64':string(contentEncoding='base64',description='attachment 必填；原文件字节，不压缩。'),
 'url':string(format='uri'),'sourceURL':source,'sourcePageID':uid,'sourceBlockID':uid,
 'collapsed':{'type':'boolean','default':True,'description':'附件默认收起为标题；false 展开预览。'},
 'height':{'type':'number','minimum':80,'maximum':1600,'default':480}},['kind'])
blocks = {'type':'array','maxItems':50,'items':block}
tools=[]
def tool(name,desc,props,required=(),read=False):
 tools.append({'name':name,'description':desc,'inputSchema':obj(props,required),
 'annotations':{'readOnlyHint':read,'destructiveHint':False,'idempotentHint':read,'openWorldHint':False}})
tool('list_pages','查找资料库中的页面/层级。先搜索，再决定归档位置。',{'parentID':uid,'query':string(),'offset':{'type':'integer','minimum':0},'limit':{'type':'integer','minimum':1,'maximum':100}},read=True)
tool('read_page','读取页面、revision、文字、块 ID、附件与引用元信息。修改前必须读取。',{'pageID':uid},['pageID'],read=True)
tool('read_attachment','读取附件元信息、文字分页或原样 Base64；返回的是当前文件版本。',{'pageID':uid,'blockID':uid,'format':string(enum=['metadata','text','base64'],default='metadata'),'offset':{'type':'integer','minimum':0},'limit':{'type':'integer','minimum':1,'maximum':100000}},['pageID','blockID'],read=True)
tool('create_page','在指定层级建立新页面，可同时写入文字和附件；isFolder=true 时不放块。',{'title':string(minLength=1,maxLength=200),'parentID':uid,'isFolder':{'type':'boolean'},'canvasWidth':{'type':'number','minimum':320,'maximum':6000},'style':style,'blocks':blocks},['title'])
tool('append_blocks','追加按输入顺序组织的资料。现有内容和手写不移动；相同文件复用引用。',{**revision,'style':style,'blocks':{**blocks,'minItems':1}},['pageID','expectedRevision','blocks'])
tool('update_block','修改普通文字/公式、来源网址，或附件的收起状态。保护锁定与批注位置；文件正文请在应用内编辑。',{**revision,'blockID':uid,'text':string(maxLength=100000),'collapsed':{'type':'boolean'},'sourceURL':source},['pageID','blockID','expectedRevision'])
tool('layout_blocks','按 blockIDs 顺序排列选定块。默认 dryRun=true 只预览；确认方案后 dryRun=false 提交。保护手写、锁定、关联批注。',{**revision,'blockIDs':{'type':'array','minItems':1,'maxItems':50,'uniqueItems':True,'items':uid},'style':style,'dryRun':{'type':'boolean','default':True}},['pageID','expectedRevision'])
def write(name,value): (OUT/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
write('agent_tools.json',tools)
envelopes=[]
for t in tools:
 required=['tool','arguments']
 if not t['annotations']['readOnlyHint']: required+=['workspaceID','requestID']
 envelopes.append(obj({'tool':{'const':t['name']},'arguments':t['inputSchema'],'workspaceID':string(),'requestID':string(minLength=8,maxLength=128)},required))
paths={}
for name,desc,content in [('status','资料库身份与接口状态','application/json'),('tools','可调用工具及 JSON Schema','application/json'),('rules','Agent 排版与归档规范','text/markdown'),('openapi.json','本 OpenAPI 文档','application/json')]:
 paths['/v1/'+name]={'get':{'operationId':name.replace('.','_'),'summary':desc,'responses':{'200':{'description':desc,'content':{content:{'schema':{'type':'string'} if content=='text/markdown' else {'type':'object'}}}}}}}
paths['/v1/call']={'post':{'operationId':'callTool','summary':'调用工具；写入需要 workspaceID、requestID，修改已有页还需 expectedRevision。','requestBody':{'required':True,'content':{'application/json':{'schema':{'oneOf':envelopes}}}},'responses':{str(code):{'description':desc} for code,desc in [(200,'成功；写入返回 page 摘要和 changedBlocks，完整正文用 read_page'),(400,'请求/参数无效'),(401,'令牌无效'),(403,'只读或来源不允许'),(404,'页面/块不存在'),(409,'版本冲突、重复请求 ID 内容不一致、工作区变化或布局受保护'),(413,'超出大小上限'),(422,'内容或排版无效'),(500,'存储错误'),(503,'接口暂不可用')]}}}
write('agent_openapi.json',{'openapi':'3.1.0','info':{'title':'Libere Agent API','version':'1.0.0','description':'Mac 本机接口。layout_blocks 的 dryRun=true 例外允许不带 requestID；不直接执行代码或抓取远程网址。'},'servers':[{'url':'http://127.0.0.1:19876'}],'security':[{'bearerAuth':[]}],'components':{'securitySchemes':{'bearerAuth':{'type':'http','scheme':'bearer'}}},'paths':paths})
print('Generated 7 tool schemas and OpenAPI.')
