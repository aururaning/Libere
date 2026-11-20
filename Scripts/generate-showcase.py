#!/usr/bin/env python3
"""Build original, editable Libere scenario notes and embedded demo attachments.

Run MakeShowcasePDFs first. IDs are stable so opening the gallery never overwrites
or duplicates the user's edited examples. No real user content is read here.
"""
from pathlib import Path
import base64
import hashlib
import json
import uuid

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / '.build/showcase-assets'
NS = uuid.UUID('082fd9ec-0eb5-41f9-9ea7-cfe3cdb41b84')
def uid(key): return str(uuid.uuid5(NS, key)).upper()
def rect(x, y, w, h): return dict(x=x, y=y, width=w, height=h)
assets = {}
notes = []
root_id = uid('gallery')
def note(key, title, parent=root_id, order=0, folder=False):
    value = dict(id=uid(key), parentID=parent, sidebarOrder=order, title=title,
                 isFolder=folder, paper='wideContinuous', canvasWidth=1123, canvasHeight=2200,
                 blocks=[], anchors=[], version={'counters': {'libere-showcase-v1': 1}},
                 revision=uid('revision/'+key), modifiedAt=816566400, deleted=False)
    if parent is None: value.pop('parentID')
    notes.append(value)
    return value
def block(page, key, kind, frame, text='', size=18, tint='paper', **extra):
    value = dict(id=uid('block/'+key), kind=kind, frame=rect(*frame), text=text,
                 fontSize=size, quote=False, tint=tint, locked=False, assetName='', pdfPage=0)
    if kind == 'text': value['textFormat'] = 'markdown'
    value.update(extra); page['blocks'].append(value); return value
def text(page, key, frame, content, **extra): return block(page,key,'text',frame,content,**extra)
def file(page, key, frame, filename, data, collapsed=False, **extra):
    if isinstance(data,str): data=data.encode()
    asset = uid('asset/'+key); assets[asset] = base64.b64encode(data).decode()
    return block(page,key,'pdf' if filename.endswith('.pdf') else 'file',frame,
                 assetID=asset,fileID=asset,assetName=filename,assetSHA256=hashlib.sha256(data).hexdigest(),
                 assetByteCount=len(data),collapsed=collapsed,**extra)
def branch(page, owner, child, label):
    a = dict(id=uid('anchor/'+child['id']), ownerID=owner['id'], label=label,
             u=(child['frame']['x']-owner['frame']['x'])/owner['frame']['width'],
             v=(child['frame']['y']-owner['frame']['y'])/owner['frame']['height'], edge='leading')
    page['anchors'].append(a); child['anchorID']=a['id']
def reference(page,key,frame,original,owner,collapsed=False):
    copy=dict(original);copy.update(id=uid('block/'+key), frame=rect(*frame), locked=False,
        reference={'noteID':owner['id'],'blockID':original['id']},collapsed=collapsed)
    copy.pop('pageAnnotations',None);copy.pop('anchorID',None);page['blocks'].append(copy);return copy
def hero(page,key,eyebrow,title,description):
    return text(page,key,(40,36,1043,200),f'{eyebrow}\n\n# {title}\n\n{description}',size=20,tint='blue')
def child(parent,key,title,content,order=0):
    n=note(key,title,parent['id'],order)
    hero(n,key+'-hero','延伸工作页',title,'这是可编辑的示例。把其中的内容替换为你自己的材料。')
    text(n,key+'-body',(40,250,1043,780),content,size=19)
    return n

gallery=note('gallery','场景展示',parent=None,order=0,folder=True)

# 01. Lecture: lecture PDF + independent annotation branches + formula + review.
classroom=note('classroom','01 · 课堂笔记｜贝叶斯更新',order=0)
hero(classroom,'class-hero','课堂笔记 / 先理解，再复习','让讲义和自己的解释待在一起',
     '左边保留讲义，右边记录理解和疑问；课后把零散笔记整理成可回答的问题。')
lecture=file(classroom,'lecture',(40,252,590,820),'第05讲-贝叶斯更新.pdf',(ASSETS/'lecture.pdf').read_bytes())
insight=text(classroom,'class-insight',(682,272,401,300),'## 我的理解\n\n后验不是把旧判断丢掉，而是用新证据更新它。\n\n==先验 + 观察 → 后验==\n\n这个例子中：正面次数增加 α，反面次数增加 β。',size=18,tint='blue')
question=text(classroom,'class-question',(682,604,401,300),'## 留给课后的问题\n\n- 为什么后验均值不是 0.8？\n- 先验换成 Beta(1, 1) 会怎样？\n- 再观察到一次反面，会如何更新？\n\n先口头解释，再动笔计算。',size=18)
branch(classroom,lecture,insight,'核心理解');branch(classroom,lecture,question,'课后疑问')
text(classroom,'class-try',(40,1110,1043,180),'## 试一试\n\n单击选中讲义，再点击右侧批注点打开对应笔记。双击“我的理解”改写一段；拖动讲义时，关联的文字分支会一起移动。手写批注独立保留。',size=18,tint='gray')
block(classroom,'class-formula','formula',(40,1322,500,160),r'\frac{10}{10+4}=\frac{5}{7}\approx 0.714',size=26)
text(classroom,'class-summary',(574,1322,509,265),'## 一句话小结\n\n先验 Beta(2, 2)，观察 8 正 2 反，得到后验 Beta(10, 4)。\n\n后验均值约 **0.714**；再看到一次反面后变为 **0.667**。',size=18)
review=child(classroom,'class-review','复习卡片｜把知识变成问题','''## 复习前先遮住答案

### 卡片 1 · 什么是后验？
结合先验与新观察后，对未知量的更新判断。

### 卡片 2 · 8 正 2 反如何更新 Beta(2, 2)？
把正面次数加入第一个参数、反面次数加入第二个参数，得到 Beta(10, 4)。

### 卡片 3 · 为什么不直接用 0.8？
0.8 只描述这 10 次观察的频率；后验均值还整合了先验信息。

## 下一次复习
- [x] 能用自己的话解释三种量
- [ ] 更换先验后重新计算
- [ ] 对照讲义检查自己的推导
- [ ] 把仍不清楚的问题带到下一次课
''')
practice=child(classroom,'class-practice','练习与计算｜把推导落到数字','''## 从计算到解释

1. 改用 Beta(1, 1) 作为先验。
2. 仍观察 8 次正面、2 次反面。
3. 后验变为 Beta(9, 3)，均值为 0.75。
4. 与原例的 0.714 比较：先验更集中时，少量新观察的影响相对更小。

## 我的推导
在这里写下计算过程，也可以用手写工具在空白区域补充公式。

## 常见混淆
“后验均值”不是“下一次一定出现正面”；参数的改变表达的是判断变化。
''',1)

# 02. Research: fictional paper, two anchors, actual Markdown draft and notebook.
research=note('research','02 · 论文构思与写作｜从证据到初稿',order=1)
hero(research,'research-hero','论文构思与写作 / 保留推理过程','资料、问题、论点和初稿，同页对照',
     '围绕“笔记结构与延迟回忆”组织一次研究提案。以下材料与数据均为自制演示。')
paper=file(research,'research-paper',(40,252,590,820),'阅读练习-结构化笔记与回忆.pdf',(ASSETS/'research.pdf').read_bytes(),locked=True)
paper['pageAnnotations']={'0':{'texts':[{'id':uid('paper-annotation'),'frame':rect(365,223,180,42),'text':'先区分问题与证据','fontSize':12}]}}
claim=text(research,'research-claim',(682,272,401,330),'## 从材料提炼问题\n\n真正想比较的是 **证据旁写解释** 这一行为，而不仅是使用哪种工具。\n\n研究问题：在材料和复习时间相同的条件下，这种组织方式是否有助于一周后回忆？',size=18,tint='blue')
limits=text(research,'research-boundary',(682,634,401,330),'## 论证还缺什么\n\n- 随机分配与基线能力\n- 一致的学习和复习时间\n- 预先确定的评分规则\n- 真实采集的数据\n\nPDF 已锁定：框和预览页固定，仍可在阅读器中添加批注。',size=18)
branch(research,paper,claim,'研究问题');branch(research,paper,limits,'证据边界')
draft_source='''# 研究提案初稿：笔记结构与延迟回忆

## 摘要草稿
本研究拟比较“证据与解释相邻组织”和线性摘录两种笔记方式。学习材料、学习时长与复习次数需要控制一致；主要结果为一周后的概念回忆评分。当前处于设计阶段，尚未开展实验。

## 1. 问题与动机
摘录并不自动等于理解。我们希望考察学习者在材料旁写出自己的解释，是否能形成更清晰的提取线索。

## 2. 可检验的假设
在相同学习和复习时间下，证据与解释成对组织的条件可能获得更高的延迟回忆分数。

## 3. 方法草案
- 随机分配；记录基线能力。
- 使用相同材料、统一时长与评分量表。
- 预先规定主要指标及缺失数据处理。
- 记录复习次数与实际笔记内容。

## 4. 图表与结果
当前 Notebook 只有模拟结果，用于练习描述，不是研究发现。

## 5. 待补材料
- [ ] 检索并阅读真实文献
- [ ] 写出评分量表和数据字典
- [ ] 完成小规模流程试运行

## 材料说明
配套 PDF 为 Libere 自制演示材料，不是已发表论文，不应作为真实文献引用。
'''
draft=file(research,'research-draft',(40,1110,620,540),'研究提案初稿.md',draft_source)
text(research,'research-writing',(694,1110,389,400),'## 写作工作流\n\n**问题 → 证据 → 解释 → 段落**\n\n展开左侧 Markdown 文件，切换“编辑”修改初稿。\n\n在子页面“论证地图”中先打磨论点，再回到这里写成连贯段落。',size=18,tint='gray')
outline=child(research,'research-outline','论证地图｜先搭结构，再写段落','''## 中心问题
相邻组织“证据与解释”能否支持延迟回忆？

| 段落任务 | 当前内容 | 下一步补证据 |
| --- | --- | --- |
| 说明问题 | 摘录可能缺少主动解释 | 检索学习与笔记研究 |
| 提出机制 | 自己写解释，形成提取线索 | 找到可操作的测量方式 |
| 设计检验 | 控制时长、材料、复习次数 | 明确随机分配与评分 |
| 讨论边界 | 学科、个体差异、材料难度 | 确定外推范围 |

## 一个段落的骨架
**论点**：先写清楚这一段要支持什么。

**证据**：标出来源、研究条件和实际观察。

**解释**：说明证据如何支持论点，以及还有什么不能推断。

## 待写
先完成方法部分，避免在没有真实数据时提前写出“研究证明”。
''')
experiment=note('research-experiment','模拟结果与分析 Notebook',research['id'],1)
hero(experiment,'experiment-hero','研究工作页 / 模拟数据','把数据、计算与解释摆在一起','Notebook 保留单元格与示例输出；无需运行即可阅读。')
nb={'nbformat':4,'nbformat_minor':5,'metadata':{'kernelspec':{'display_name':'Python 3','language':'python','name':'python3'},'language_info':{'name':'python'}},'cells':[
    {'cell_type':'markdown','id':'intro','metadata':{},'source':['# 模拟结果比较\n','仅用于演示，不是实测研究结果。']},
    {'cell_type':'code','id':'means','metadata':{},'execution_count':1,'source':['linear = {"immediate": 78, "delayed": 62}\n','paired = {"immediate": 83, "delayed": 71}\n','difference = paired["delayed"] - linear["delayed"]\n','print(f"一周后均分差：{difference} 分（模拟）")'], 'outputs':[{'output_type':'stream','name':'stdout','text':['一周后均分差：9 分（模拟）\n']}]},
    {'cell_type':'markdown','id':'interpretation','metadata':{},'source':['## 解释边界\n','这只是两组模拟均值之差，没有原始数据、方差与分配过程，不能据此声称因果或统计显著。']} ]}
file(experiment,'research-notebook',(40,252,680,700),'模拟结果分析.ipynb',json.dumps(nb,ensure_ascii=False,indent=2))
text(experiment,'experiment-notes',(752,252,331,430),'## 先读输出，再改问题\n\n当前已保存输出：均分差为 **9 分**。\n\n试着修改一项模拟值，观察解释应如何调整。\n\n实际执行需要在 Mac 上选择 Python 环境，并主动启动内核。',size=18,tint='blue')
reference(experiment,'research-reference',(40,1000,680,36),paper,research,collapsed=True)

# 03. Code: real editable code, tests, Markdown and an independent work log.
code=note('code','03 · 代码库管理｜一次可追踪的重构',order=2)
hero(code,'code-hero','代码库管理 / 阅读、修改、验证','把代码入口和变更理由放在同一处',
     '用一个排序模块演示：读源码 → 明确行为 → 记录方案 → 检查回归。这里是示例文件，不连接远程仓库。')
source='''"""Libere demo: deterministic ranking for small note search results."""
from dataclasses import dataclass

@dataclass(frozen=True)
class Candidate:
    id: str
    title: str
    relevance: float
    updated_at: int

def rank(candidates):
    """Relevance descending; recent first; stable id as final tie-breaker."""
    return sorted(candidates, key=lambda c: (-c.relevance, -c.updated_at, c.id))

if __name__ == "__main__":
    items = [Candidate("b", "贝叶斯复习", 0.9, 10),
             Candidate("a", "课堂要点", 0.9, 10),
             Candidate("c", "项目说明", 0.5, 20)]
    print([c.id for c in rank(items)])  # ['a', 'b', 'c']
'''
tests='''import unittest
from ranker import Candidate, rank

class RankingTests(unittest.TestCase):
    def test_relevance_comes_first(self):
        low = Candidate("low", "", 0.4, 100)
        high = Candidate("high", "", 0.8, 1)
        self.assertEqual([c.id for c in rank([low, high])], ["high", "low"])

    def test_ties_have_repeatable_order(self):
        a = Candidate("a", "", 0.9, 10)
        b = Candidate("b", "", 0.9, 10)
        self.assertEqual(rank([a, b]), rank([b, a]))

    def test_does_not_mutate_input(self):
        original = [Candidate("b", "", 0.9, 10), Candidate("a", "", 0.9, 10)]
        snapshot = list(original)
        rank(original)
        self.assertEqual(original, snapshot)

if __name__ == "__main__":
    unittest.main()
'''
ranker=file(code,'ranker',(40,252,650,640),'ranker.py',source)
text(code,'code-map',(722,252,361,350),'## 仓库导航\n\n**ranker.py**\n排序规则与数据结构。\n\n**test_ranker.py**\n相关性、稳定顺序与输入保护。\n\n**README.md**\n入口、约定和验证方式。',size=18,tint='blue')
text(code,'code-decision',(722,634,361,330),'## 为什么这次要改\n\n同分结果需要稳定顺序，方便复现问题。\n\n优先比较相关性，再比较更新时间，最后用 id 兜底。\n\n**讨论点**：更新时间是否应该参与排序？',size=18)
file(code,'ranking-tests',(40,932,650,520),'test_ranker.py',tests)
readme=file(code,'code-readme',(722,1000,361,36),'README.md','''# Note Ranker · 演示代码库

一个用于笔记搜索结果排序的小型 Python 示例，无第三方依赖。

## 行为约定
相关性从高到低；同分时按更新时间；最后按稳定 id 排序。
函数返回新列表，不修改输入。

## 本地验证
把 ranker.py 与 test_ranker.py 放在同一目录，运行：

```bash
python3 -m unittest -v test_ranker.py
```

Libere 中可以阅读、编辑文件并记录变更；这里不模拟 Git 提交或远程同步。
''',collapsed=True)
text(code,'code-try',(722,1070,361,330),'## 试一试\n\n打开源码块的“编辑”，修改函数注释并保存。\n\n到“变更记录”页，补充这次修改的理由、验证方法与结果。\n\n源码不会自动执行。',size=18,tint='gray')
changes=child(code,'code-changes','变更记录｜让下一次阅读有上下文','''## 变更 001 · 为同分结果添加稳定排序

**触发问题**：同分结果的展示顺序随输入排列变化，排查问题时不容易复现。

**方案**：相关性降序 → 更新时间降序 → id 升序。

**影响范围**：只有同分或同时间的结果改变顺序；返回值仍为新列表。

## 验证记录
- [x] 相关性优先于更新时间
- [x] 不同输入顺序得到一致的同分排列
- [x] 输入列表保持不变
- [ ] 用实际产品样例确认“最近更新优先”符合预期

## 下一次修改前
先把变化的用户行为写出来，再改实现；把实际验证结果记录在这里。
''')
reference(changes,'ranker-ref',(40,1070,1043,36),ranker,code,collapsed=True)
backlog=child(code,'code-backlog','问题与设计｜把待办变成可验证行为','''## 当前问题
同分时“最近更新优先”是否符合使用者的期待？

## 备选方案
| 方案 | 用户能看到的变化 | 需要验证什么 |
| --- | --- | --- |
| 最近更新优先 | 新编辑的笔记靠前 | 是否符合查找意图 |
| 标题排序 | 同分结果稳定易扫读 | 中英文标题如何处理 |
| 保留用户顺序 | 手动整理结果不跳动 | 排序与分组是否冲突 |

## 验收条件
- 同样的数据重复计算，顺序一致。
- 排序规则变化有清楚的说明。
- 文档、实现和测试描述相同的行为。

## 我的结论
在这里写下你最终选择的规则与理由。
''',1)

# 04. Project: actual project brief, three editable lanes, milestones and decisions.
project=note('project','04 · 项目管理｜校园地图 v1.0',order=3)
hero(project,'project-hero','项目管理 / 目标、执行、决策','让每个任务都能回到项目目标',
     '以“校园无障碍地图”为虚构示例，把范围、任务、里程碑与会议决策组织起来。')
text(project,'project-goal',(40,252,1043,240),'## 这次交付什么\n\n**目标**：让新同学找到教学楼入口、坡道与电梯位置。\n\n**v1.0 范围**：3 栋教学楼、可检索的点位清单、基础路线说明。\n\n**完成标准**：点位有来源、位置经过核对、关键路线有文字说明。',size=19,tint='blue')
text(project,'lane-todo',(40,524,325,410),'## 待开始\n\n- [ ] 补齐图书馆入口信息\n- [ ] 确认坡道照片授权\n- [ ] 整理电梯开放时间\n\n**下一步**\n先记录需要核实的信息，避免把猜测放进正式地图。',size=18)
text(project,'lane-doing',(399,524,325,410),'## 进行中\n\n- [ ] 核对 A 楼 6 个点位\n- [ ] 编写新生路线说明\n- [ ] 检查手机端阅读顺序\n\n**本周重点**\n先完成可用的一条路线，再扩展覆盖范围。',size=18,tint='blue')
text(project,'lane-done',(758,524,325,410),'## 已完成\n\n- [x] 确定 v1.0 范围\n- [x] 建立点位数据字段\n- [x] 完成页面结构草图\n\n**保留依据**\n已完成项附上结果或检查记录。',size=18,tint='gray')
text(project,'project-milestones',(40,970,620,330),'## 四周节奏\n\n| 阶段 | 交付物 | 检查点 |\n| --- | --- | --- |\n| 第 1 周 | 点位字段与范围 | 统一信息口径 |\n| 第 2 周 | 第一条完整路线 | 实地核对 |\n| 第 3 周 | 三栋楼内容 | 同学试用 |\n| 第 4 周 | v1.0 与说明 | 修复问题、归档 |',size=17)
text(project,'project-risks',(694,970,389,330),'## 风险与处理\n\n**信息过期**\n在点位中记录核对日期。\n\n**范围不断扩大**\n新需求先进入下一版清单。\n\n**责任不清**\n每次会议写清行动项和下一次检查时间。',size=18)
brief=file(project,'project-brief',(40,1332,1043,36),'项目说明.md','''# 校园无障碍地图 v1.0 · 演示项目

## 目标
帮助新同学找到入口、坡道、电梯及基本路线。

## 范围
三栋教学楼；可搜索点位；清晰的路线说明。暂不包含实时导航与拥堵预测。

## 数据字段
名称、类别、建筑、楼层、文字位置、核对日期、来源、待确认问题。

## 验收
- [ ] 每个点位有来源与核对日期
- [ ] 关键路线有可理解的文字说明
- [ ] 手机端可以顺序阅读
- [ ] 待核实的信息已明确标注
''',collapsed=True)
meeting=child(project,'project-meeting','会议与决策｜记录为什么这么做','''## 第 2 周检查会 · 演示记录

### 需要决定的问题
先扩展到更多建筑，还是先完成一条经过核对的完整路线？

### 决定
先完成 A 楼的完整路线，用它验证信息字段和阅读方式，再扩展到另外两栋楼。

### 依据
只有点位数量没有路线说明，不能验证新同学能否实际使用。

| 行动项 | 负责人角色 | 检查时间 | 交付物 |
| --- | --- | --- | --- |
| 核对 A 楼点位 | 内容整理 | 本周结束 | 有来源的清单 |
| 编写路线说明 | 内容整理 | 下次会议前 | 一条完整路线 |
| 组织试读 | 体验检查 | 第 3 周 | 问题记录 |

## 下次会议先看
路线是否走得通、说明是否读得懂、哪些信息仍未确认。
''')
retro=child(project,'project-retro','复盘与下一版｜让经验留下来','''## 交付前核对
- [ ] 点位、路线和说明对应一致
- [ ] 所有“待确认”条目已处理或标注
- [ ] 主要页面完成手机端试读
- [ ] 对外说明与实际功能相符

## 复盘三个问题
**什么有效？** 从一条完整路线开始，比先堆积大量点位更容易发现缺口。

**哪里卡住？** 信息来源和核对时间不统一，导致重复确认。

**下一次怎样改？** 采集时就填写统一字段，每周先关闭未确认问题。

## 下一版候选
- [ ] 增加校外交通连接信息
- [ ] 提供可打印路线说明
- [ ] 建立定期核对流程
''',1)

scenarios=[
    dict(id='classroom',pageID=classroom['id'],title='课堂笔记',subtitle='讲义旁边，留下自己的理解。',symbol='graduationcap',
         detail='PDF 讲义 · 公式推导 · 两个独立批注点 · 复习卡片',step='选中讲义，点击批注点；双击旁边的文字改写解释。',children=[review['id'],practice['id']]),
    dict(id='research',pageID=research['id'],title='论文构思与写作',subtitle='让每个论点，都找得到来处。',symbol='doc.text.magnifyingglass',
         detail='阅读批注 · 论证地图 · Markdown 初稿 · Notebook',step='查看锁定 PDF 的批注，再编辑下方的研究提案初稿。',children=[outline['id'],experiment['id']]),
    dict(id='code',pageID=code['id'],title='代码库管理',subtitle='把代码和变更理由放在一起。',symbol='chevron.left.forwardslash.chevron.right',
         detail='Python 源码 · 测试文件 · README · 跨页引用',step='编辑源码注释，再到“变更记录”补上修改理由。',children=[changes['id'],backlog['id']]),
    dict(id='project',pageID=project['id'],title='项目管理',subtitle='从一个目标，走到一次交付。',symbol='rectangle.3.group',
         detail='三列任务板 · 里程碑 · 会议决策 · 项目复盘',step='双击任务列修改清单，拖动文字框安排你自己的工作区。',children=[meeting['id'],retro['id']])]

# Keep ownership and visible layout deterministic, with no accidental overlaps.
ids=[n['id'] for n in notes]
assert len(ids)==len(set(ids))
for page in notes:
    for b in page['blocks']:
        assert b['frame']['x']>=28 and b['frame']['y']>=28
        assert b['frame']['x']+b['frame']['width']<=1123
        for other in page['blocks']:
            if b is other: continue
            a,c=b['frame'],other['frame']
            assert not (a['x']<c['x']+c['width'] and a['x']+a['width']>c['x'] and a['y']<c['y']+c['height'] and a['y']+a['height']>c['y']), (page['title'],b['id'],other['id'])
catalog=dict(version=1,rootID=root_id,scenarios=scenarios,
             backup=dict(format=1,workspace=dict(schemaVersion=1,notes=notes,pending=[]),assets=assets))
target=ROOT/'Sources/MarginNotes/Resources/Showcase.json'
target.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
(ASSETS/'Libere-Showcase.marginbackup').write_text(json.dumps(catalog['backup'],ensure_ascii=False,separators=(',',':')))
print(json.dumps(dict(rootID=root_id,pages=len(notes),blocks=sum(len(n['blocks']) for n in notes),assets=len(assets),path=str(target)),ensure_ascii=False))
