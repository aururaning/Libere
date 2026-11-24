#!/usr/bin/env python3
"""Build original, editable Libere scenario notes and embedded demo attachments.

Run MakeShowcasePDFs first. IDs are stable so opening the gallery never overwrites
or duplicates the user's edited examples. No real user content is read here.
"""
from pathlib import Path
import base64
import hashlib
import json
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]

def feature_guide():
    """App-bundled help only; adding a topic never creates a user-library page."""
    def topic(key, title, summary, steps, shortcuts=(), keywords=(), note=None):
        return dict(id=key, title=title, summary=summary, steps=steps,
                    shortcuts=list(shortcuts), keywords=list(keywords), note=note)
    def section(key, title, symbol, summary, *topics):
        return dict(id=key, title=title, symbol=symbol, summary=summary, topics=list(topics))
    return dict(version=1, title='Libere 功能教程',
                subtitle='按功能查找入口和操作。这里的说明不会添加到你的资料库。', sections=[
        section('start', '开始使用', 'sparkles', '先建一页，再把资料和想法放进来。',
            topic('start.library', '选择资料库', '资料库是你自己管理的一个文件夹。',
                  ['首次打开时选择本地文件夹或 iCloud Drive 文件夹。', '以后从「笔记 → 存储位置…」查看或切换资料库。', '切换位置会打开所选文件夹中的资料库，不会自动搬迁旧资料。']),
            topic('start.page', '新建笔记和子页面', '每张笔记都是一张可以自由排布的画布。',
                  ['按 ⌘N 新建笔记，在顶部输入标题。', '点标题栏「子页面」，或在侧栏右键新建子页面。', '点侧栏标题切换页面，用左侧展开按钮查看层级。'], ['⌘N', '⌘⇧N']),
            topic('start.first-actions', '完成第一次整理', '先完成“放资料、写解释、整理位置”三个动作。',
                  ['在 Finder 复制一个文件，回到笔记，将鼠标放到画布上按 ⌘V。', '双击画布空白处新建文字框，写下自己的理解。', '单击选中内容块，拖动移动手柄安排位置。'], ['⌘V'], ['快速入门', '第一次']),
            topic('start.guide', '教程与示例场景', '功能教程用于查操作，示例场景用于动手试。',
                  ['从「笔记 → 功能教程」随时打开这份说明，也可以在顶部搜索。', '需要练习时，手动打开「笔记 → 示例场景」。', '已经编辑过的示例会保留；把示例移入回收站后，普通重启不会把它们重新放回来。'], note='首次创建资料库后，右上角浮层会指出问号入口；点击「查看教程」才打开完整说明。覆盖安装或切换资料库不会重复提示。')),
        section('canvas', '画布与滚动', 'rectangle.and.hand.point.up.left', '在页面上移动、缩放和安排内容。',
            topic('canvas.select-move', '选择、移动和调整大小', '内容块的位置由你决定。',
                  ['单击内容块将它选中；拖动出现的移动手柄移动整个块。', '拖动右下角调整角改变大小。', '双击文字进入编辑，点击画布空白处或按 Esc 结束选择。']),
            topic('canvas.zoom', '缩放与铺满宽度', '放大阅读时，画布位置和内容编辑是两件独立的事。',
                  ['使用触控板双指捏合，或「笔记」菜单中的放大、缩小。', '按 ⌘0 将页面铺满可视宽度。', '用右侧画布设置选择纸张；纵向长页会随内容向下延展。'], ['⌘+', '⌘−', '⌘0'], ['缩放', '连续纸张']),
            topic('canvas.wheel', '滚轮跟随选择', '先决定滚动整页还是某个资料块。',
                  ['没有选中内容块时，滚轮滚动外层页面。', '选中可滚动的 PDF、代码或其他内容块后，滚轮滚动该块。', '到块的顶部或底部时，滚轮仍由该块接收；点击空白处取消选择后再滚动整页。'], note='文件夹介绍和目录区域同样按当前选择接收滚轮。'),
            topic('canvas.grid-layout', '点阵、吸附和整理版面', '用辅助工具整理普通内容块，同时保留手写和批注的位置。',
                  ['打开右侧画布设置，按需切换「显示点阵」和「文字吸附对齐」。', '拖动文字框接近批注点时，查看吸附提示。', '需要整体整理时使用「整理版面」；不适合自动调整的内容会提示手动处理。'], note='手写不会参与吸附或自动排版；锁定内容、关联批注和页内批注也会受到保护。')),
        section('text', '文字与公式', 'textformat', '把简短想法、长文和数学推导写在画布上。',
            topic('text.markdown', 'Markdown 文字框', '直接输入标题、列表、引用、表格与公式。',
                  ['双击文字框进入编辑；在空白处双击可以新建文字框。', '用 # 标题、- 列表、**加粗** 和 ==荧光标记== 组织内容。', '结束编辑后查看排版预览；需要继续修改时再双击。'], ['⌘⇧T'], ['Markdown', '表格', '清单']),
            topic('text.style', '字体、字号和强调', '可以按内容需要调整文字的呈现。',
                  ['选中文字框，在右侧属性面板调整字体、字号和底色。', '在编辑器中选中文字后，可使用加粗、斜体和荧光标记。', '需要醒目的批注时打开「左侧强调线」。'], ['⌘B', '⌘I', '⌘⇧H'], ['富文本', '宋体', '等宽']),
            topic('text.math', '行内公式和公式块', '数学表达可以嵌在段落中，也可以单独摆放。',
                  ['在 Markdown 中用 $…$ 输入行内公式，用 $$…$$ 输入独立公式。', '按 ⌘⇧M 或点工具栏「公式」，创建可移动的公式块。', '选中公式块后点「编辑公式」，修改 LaTeX 源码。'], ['⌘⇧M'], ['LaTeX', '数学', '分式', '离线公式'], note='公式随应用离线排版；输入有误时保留源码供你修改。'),
            topic('text.paste', '在文字中粘贴', '文字输入与画布粘贴使用各自合适的位置。',
                  ['光标在文字编辑器中时，⌘V 将普通文本粘到文字光标处。', '没有在编辑文字时，粘贴普通文本会生成新的文字框。', '复制的是文件或图片时，在主画布粘贴会作为资料块处理。'], ['⌘V'], ['剪贴板', '文本'])) ,
        section('ink', '手写与批注点', 'pencil.and.outline', '在页面、资料旁边和资料内部留下自己的理解。',
            topic('ink.tools', '画布手写', '手写笔迹独立保存，不会被自动整理移动。',
                  ['在工具栏选择「手写」。', '选择压感笔、均匀线条、荧光笔或整笔橡皮，再调整颜色和粗细。', '在空白画布上书写；切回「选择」继续操作内容块。'], ['⌘Z'], ['Apple Pencil', '橡皮', '荧光笔']),
            topic('ink.branches', '页外文字批注', '把解释接在正在阅读的资料旁边。',
                  ['选中资料块，在右侧点「添加页外文字批注」。', '在出现的文字框中输入说明，拖动它安排位置。', '点击资料旁的批注点可以再次打开对应批注。'], ['Esc'], ['分支', '连线', '批注']),
            topic('ink.anchors', '多个独立批注点', '同一份资料可以有多个位置不同的批注入口。',
                  ['选中资料后点「自定批注点位置」，再在画布上点击落点。', '在右侧批注点列表中分别调整位置和关联方式。', '需要拆开文字与资料时，对选中文字使用「解除批注关联」。'], note='每个批注点独立配置；手写笔迹不参与文字吸附。'),
            topic('ink.connections', '查看或隐藏批注连线', '连线帮助追溯想法，也可以暂时隐藏以专注阅读。',
                  ['在「笔记」菜单切换「显示/隐藏批注连线」。', '隐藏只改变显示，不会删除批注或其关联。'])) ,
        section('pdf', 'PDF 与阅读器', 'doc.richtext', '在画布预览资料，或进入独立窗口专注阅读。',
            topic('pdf.reader', '打开独立阅读窗口', '画布、属性面板和搜索入口会复用同一份资料的阅读窗口。',
                  ['双击 PDF，或在右侧点「阅读与页内批注」。', '在阅读窗口中缩放、浏览资料，也可以切换全屏。', '关闭阅读窗口后，原画布和批注仍然保留。']),
            topic('pdf.pages', '翻页和跳转页码', '无需从第一页一直翻到目标位置。',
                  ['使用资料预览或阅读器的上一页、下一页按钮。', '在页码框输入目标页码并确认跳转。', '不同页面的页内批注分别保存，页外批注不随翻页消失。'], ['Enter'], ['页码', '翻页']),
            topic('pdf.annotations', 'PDF 页内文字和手写批注', '在原文对应位置写下补充内容。',
                  ['打开阅读器，选择文字批注或手写工具。', '文字工具下双击页面放置文字；手写工具下直接书写。', '修改完成后切回选择或关闭窗口，批注会保存到资料库。'], note='批注与原 PDF 分开保存，导出原件不会把这些批注烧录进 PDF。'),
            topic('pdf.lock', '锁定 PDF', '固定画布中的资料位置和预览页，继续保留批注能力。',
                  ['选中 PDF，打开「锁定位置与大小」。', '锁定后不再拖动、缩放其外框或切换画布预览页。', '仍可打开独立阅读器浏览其他页并做批注；需要移动时再解锁。']),
            topic('pdf.collapse', '展开、收起与导出原件', '暂时收起资料，为思考腾出空间。',
                  ['使用资料块标题栏的展开/收起按钮切换显示。', '需要一份原文件时，在阅读器中选择「导出原件」。', '收起不会删除文件或批注，展开后可继续阅读。'])) ,
        section('files', '图片与各种文件', 'doc.on.doc', '支持预览的格式直接阅读，其他文件也能作为资料卡收纳。',
            topic('files.image', '图片预览与批注', '图片可以和文字、PDF 放在同一画布上。',
                  ['复制图片文件或截图，在主画布按 ⌘V。', '选中图片可调整资料块大小；双击进入独立阅读。', '使用页内文字和手写工具，在图片对应位置留下说明。'], ['⌘V'], ['PNG', 'JPEG', 'HEIC', '截图']),
            topic('files.generic', '文档、音视频与压缩包', '没有内嵌预览的格式仍然可以放进页面。',
                  ['复制文件并粘贴到画布，查看生成的文件卡片。', '卡片显示文件名和类型。', '点「打开原文件」，使用系统关联的应用继续处理。'], note='通用文件卡片不把二进制内容当文本解析，也不会因粘贴而自动执行文件。'),
            topic('files.index', '添加已有文件索引', '对已经位于资料库内的文件，直接记录原路径。',
                  ['把文件放到资料库文件夹中。', '选择「添加文件索引 → 添加索引并展开」或「添加索引并收起」。', '也可以把库内文件从 Finder 拖到画布；在文件夹页面拖入会生成子页面。'], note='普通“添加索引”不复制文件。剪贴板粘贴库外文件则使用归档流程。'),
            topic('files.reference', '跨页引用已有资料', '多个页面可以指向同一个库内原文件。',
                  ['在工具栏点「引用」，搜索文件名或来源页面。', '选择资料，把它放到当前页面；也可选择引用为子页面。', '点击内容块的来源入口可以回到原页面。'], note='引用共享原文件路径；修改原文件会影响引用它的其他页面。')),
        section('code', '代码与 Notebook', 'curlybraces', '阅读源码、修改文件、运行实验，并保留解释和输出。',
            topic('code.source', '编辑代码和文本文件', '源码块直接编辑资料库里的原文件。',
                  ['展开源码、Markdown 或 HTML 文件，点「编辑」。', '修改后查看底部保存状态，或按 ⌘S 保存。', '需要另存修改稿时使用「导出修改稿」。'], ['⌘S'], ['Python', 'Swift', 'JSON', '源码'], note='保存会更新原文件；若发现外部修改冲突，应用会保留恢复稿并提示处理。'),
            topic('code.notebook-start', '启动 Notebook 内核', '先选择 Python 环境，再决定运行哪些代码。',
                  ['展开 .ipynb 文件，进入编辑。', '在 Mac 上选择 Python 路径、刷新内核，选择可用内核后点「启动内核」。', '点单元格运行按钮或「运行全部」，在输出区查看结果。'], ['Shift+Enter'], ['Jupyter', 'Python环境'], note='代码不会因粘贴或打开自动执行。iPad 可查看、编辑和同步 Notebook，内核运行需要 Mac。'),
            topic('code.notebook-cells', '管理 Notebook 单元格', '增删和调整单元格时，仍可继续编辑原有内容。',
                  ['打开单元格菜单，在上方或下方插入代码/Markdown。', '使用上移、下移、类型转换或删除来调整结构。', 'Shift+Enter 运行并前进；在末尾会创建下一格。'], ['Shift+Enter'], note='代码单元需要内核就绪才能运行；普通文字撤销和“撤销单元格操作”分别保留。'),
            topic('code.notebook-output', '输出、停止与导出', '控制运行状态，并保存可继续工作的 Notebook。',
                  ['运行卡住时点「中断」；不再使用时点「停止」。', '使用单格「清除输出」或「清除所有输出」整理显示。', '点「导出 Notebook」保存一份带当前单元和输出的文件。'], ['⌘Z'], ['重启内核', '工作目录']),
            topic('code.web', '网页链接与 HTML', '用卡片、已获取的 HTML 或内嵌浏览器查看网页。',
                  ['复制 http/https 链接，在画布粘贴生成网页卡片。', '使用工具栏的网页菜单选择卡片、HTML 或浏览器模式。', '需要外部浏览器时使用链接的打开入口。'], ['⌘⌥⇧V'], note='HTML 获取需要联网，并可能无法完整保留依赖脚本或外部资源的网页。')),
        section('organize', '文件夹与文件管理', 'folder', '侧栏层级会和你管理的原文件一起整理。',
            topic('organize.folder', '文件夹、介绍与目录', '让一个文件夹成为主题或项目首页。',
                  ['在侧栏新建文件夹，输入清晰的名称。', '打开文件夹，点「编辑介绍」撰写 Markdown 说明。', '使用「插入子页面」或「插入目录」，把说明与下面的内容连接起来。']),
            topic('organize.rename-move', '重命名和移动页面', '管理页面时，同步整理它拥有的原文件。',
                  ['侧栏选中页面后按 Enter 重命名，或右键选择「重命名」。', '拖动侧栏项目调整层级；也可右键「移动到…」选择目标。', '需要核对实际位置时，右键选择「打开原文件夹」。'], ['Enter', '⌘Z'], note='同名目标会被拒绝以保护已有文件；引用路径和已打开编辑器的路径会一起更新。'),
            topic('organize.order', '层级、顺序和展开', '把正在做的事情放在容易找到的位置。',
                  ['用侧栏展开按钮显示或收起子项目。', '拖到条目之间调整顺序，拖到文件夹内部改变归属。', '移动前留意插入位置提示，完成后用 ⌘Z 撤销不满意的整理。'])) ,
        section('find', '搜索、链接与标签', 'magnifyingglass', '从关键词找到内容，再通过来源和引用继续阅读。',
            topic('find.search', '快速搜索与跳转', '集中搜索标题、笔记内容、文件名、标签和批注。',
                  ['按 ⌘K 打开搜索面板。', '输入关键词；可组合多个词，或用引号搜索短语。', '选择结果跳到对应页面、内容块或页内批注。'], ['⌘K'], note='搜索使用资料库已有的索引与笔记文本，不会为了搜索下载并扫描所有原文件。'),
            topic('find.links', '插入页面引用', '把相关页面串起来，页面改名后仍可追踪。',
                  ['编辑文字时输入 [[，搜索并选择一个目标页面。', '接受候选项后插入页面链接。', '在预览里点击链接；画布选择状态下可用 ⌘ 单击跳转。'], ['[[', '⌘单击'], ['双向链接', 'Wiki']),
            topic('find.tags', '标签与反向链接', '给页面加分类，并找出谁引用了它。',
                  ['在页面的标签区域添加或移除标签。', '搜索时输入 #标签，再加关键词缩小范围。', '查看反向链接列表，打开引用当前页的其他页面。'], ['#标签'], ['backlinks', '标签过滤']),
            topic('find.source', '复制内容后回到来源', '应用内复制的内容保留原页面和内容块的来源。',
                  ['选中内容块后复制，切换到另一个页面再粘贴。', '在新块上使用来源入口跳回原页面。', '若复制的是文件，仍共用同一个原文件，不再次归档。'], ['⌘C', '⌘V'], ['来源引用', '跨页复制'])) ,
        section('selection', '多选、锁定与撤销', 'square.on.square', '成组整理内容，并随时撤回不满意的操作。',
            topic('selection.multi', '框选与追加选择', '一次选择多个普通内容块。',
                  ['在选择工具下，从画布空白处拖出选框。', '按住 Shift 单击内容块，追加或取消单个选择。', '拖动选中组的移动手柄，让整组一起移动。'], ['Shift+单击', 'Esc']),
            topic('selection.align', '对齐与等距分布', '用多选工具栏把普通资料块排整齐。',
                  ['先选中两个或更多内容块。', '打开「对齐与分布」，选择左/右/上/下或居中对齐。', '至少选择三个适合的块后，可使用水平或垂直等距分布。'], note='手写、锁定内容和关联批注不参与自动调整，避免改变已有批注位置。'),
            topic('selection.lock', '锁定、复制、剪切与删除', '用锁定保护暂时不想改变的内容。',
                  ['选中单个块或多个块，使用「锁定」保护位置。', '按 ⌘C 复制；未锁定的块可用 ⌘X 剪切。', '选中块后用删除键移除；需要改变锁定内容时先解锁。'], ['⌘C', '⌘X', 'Delete']),
            topic('selection.undo', '文字撤销与画布撤销', '不同编辑动作各自保留合适的撤销记录。',
                  ['正在编辑文字时，⌘Z 撤销输入；⌘⇧Z 重做。', '选择画布后，⌘Z 撤销内容块、页面和布局操作。', '需要明确撤销画布操作时，使用「笔记 → 撤销画布操作」。'], ['⌘Z', '⌘⇧Z', '⌘⌥Z'], note='多文件粘贴是一组操作。撤销插入会移除页面中的块，已归档的原文件保留，便于恢复。')),
        section('clipboard', '剪贴板快速整理', 'doc.on.clipboard', '按鼠标位置放下内容，再由应用判断引用还是归档。',
            topic('clipboard.location', '在鼠标位置粘贴', '主画布中的粘贴位置由鼠标指针决定。',
                  ['先切换到要整理的笔记页面。', '把鼠标放到希望出现内容的位置，按 ⌘V。', '多个文件从这个位置依次排入，原有内容不会被自动挪走。'], ['⌘V'], note='指针离开画布时使用当前页最近的画布位置或可视区域作为落点。独立阅读器里的普通文字粘贴保持原编辑行为。'),
            topic('clipboard.inside', '复制的是库内文件', '能复用原路径时优先引用，减少等待。',
                  ['在 Finder 复制资料库文件夹里的文件。', '回到主画布粘贴。', '应用直接建立原路径的引用，不再复制一份文件。'], ['⌘C', '⌘V'], ['路径', '索引', '速度']),
            topic('clipboard.outside', '复制的是库外文件', '归档到当前页面对应的文件夹，资料可独立保存。',
                  ['在 Finder 复制一个或多个外部文件，再到画布粘贴。', '应用在后台复制到当前页面文件夹，按 PDF、图片、文档、数据等类型分类。', '查看归档状态；同名文件自动编号，原位置的文件保留。'], ['⌘V'], note='文件夹和目录包不作为普通文件粘贴；通用文件卡片不承诺内嵌预览所有格式。'),
            topic('clipboard.bytes', '复制的是截图、图片或 PDF 数据', '即使剪贴板没有原文件路径，也能保存成新资料。',
                  ['复制截图、图片，或复制提供 PDF 数据的内容。', '在主画布粘贴，应用先保存为页面分类文件夹里的新文件。', '归档后在鼠标位置生成资料块，可以继续移动和批注。'], ['⌘V'], ['无路径', '剪贴板图片', 'PNG', 'TIFF']),
            topic('clipboard.internal', '复制的是 Libere 内容块', '保留内容样式、批注关联和可追踪的来源。',
                  ['选择要复制的内容块，按 ⌘C。', '切换页面，将鼠标放好后按 ⌘V。', '从新块的来源入口回到原页面；引用文件继续使用原文件身份。'], ['⌘C', '⌘V'], note='跨资料库整理时，先在 Finder 复制原文件，再粘贴到目标资料库。')),
        section('storage', '保存与 iCloud', 'externaldrive', '知道资料放在哪里，也知道什么时候需要等待下载。',
            topic('storage.save', '自动保存与手动保存', '文字、布局和批注会保存到当前资料库。',
                  ['修改后查看界面的保存状态。', '需要确认已落盘时按 ⌘S。', '编辑原文件发生冲突时，按提示查看 Recoveries 中保留的修改稿。'], ['⌘S']),
            topic('storage.icloud', 'iCloud Drive 文件', '云端文件需要先下载到本机，才可阅读或编辑。',
                  ['选择 iCloud Drive 内的文件夹作为资料库。', '遇到云端占位资料，在卡片中点「下载文件」。', '也可从资料库菜单选择「下载本页的 iCloud 文件」。'], note='打开资料库也可能等待索引下载。可在 Finder 为常用资料和重要索引选择“保留下载”。'),
            topic('storage.cache', '释放闲置的本地下载', '节省本机空间，同时保留 iCloud 中的原文件。',
                  ['在「存储位置…」中查看 iCloud 文件设置。', '可开启对已上传、7 天未查阅文件的自动释放。', '需要手动处理时使用「释放本页未使用的本地下载」。'], note='正在使用、未上传、有冲突的文件以及资料库索引会受到保护；系统自身的 iCloud 存储优化另行管理。'),
            topic('storage.move', '搬迁或备份整个资料库', '完整迁移时需要带走资料库目录中的原文件。',
                  ['先完成当前编辑并确认保存状态。', '在 Finder 中复制或移动整个资料库文件夹到目标位置。', '回到「存储位置…」选择新位置，确认页面和原文件均可打开。'], note='“导出索引与批注”只导出笔记结构和批注，不能替代整个资料库文件夹的备份。')),
        section('agent', '接入 AI Agent', 'sparkle.magnifyingglass', '让外部 Agent 帮你检索、整理和记录，写入权限由你控制。',
            topic('agent.connect', '连接本机 Agent', '通过应用提供的配置接入支持 MCP 或 HTTP 的客户端。',
                  ['打开「笔记 → Agent 接入…」。', '开启本机 Agent API，点「复制 MCP 配置」粘贴到对应客户端。', '需要自定义对接时，可复制 HTTP 示例和地址。'], ['MCP', 'HTTP'], note='配置中的访问令牌用于授权本机客户端，不要公开分享。'),
            topic('agent.write', '控制读取与写入', '先决定 Agent 能否保存资料和改变排版。',
                  ['只想查询时，关闭「允许 agent 保存资料与调整排版」。', '需要整理时再开启写入，并说明目标页面、来源和希望保留的内容。', '完成后检查结果，不满意的画布改动可用撤销恢复。'], ['⌘Z'], ['只读', '权限']),
            topic('agent.layout', '让 Agent 按规则整理', '把整理要求交给 Agent，同时保护现有手写和批注。',
                  ['在接入页复制「排版与操作规范」给客户端。', '让 Agent 先读取当前页面，再追加说明、来源和资料索引。', '需要重排时先查看方案，再提交布局；锁定和关联批注会受到保护。'], note='外部 Agent 的能力、连接方式和费用由其客户端决定。')),
        section('recovery', '导出与回收站', 'archivebox', '保留可恢复的整理过程，区分页面记录和原文件。',
            topic('recovery.export', '导出索引与批注', '把页面结构和批注保存为可重新导入的文件。',
                  ['打开资料库菜单，选择「导出索引与批注」。', '选择保存位置，保留生成的备份文件。', '需要恢复这些记录时使用「导入索引与批注」。'], note='导出不包含库内原文件。完整备份请同时保存整个资料库文件夹。'),
            topic('recovery.trash', '移入回收站与恢复', '先暂时收起不需要的页面，保留恢复机会。',
                  ['在侧栏右键页面，选择「移入回收站」。', '含子页面时留意确认提示，整棵层级会一起处理。', '打开回收站，在目标条目点「恢复」。'], ['⌘⌫'], note='页面移入回收站不等于删除磁盘上的原文件。'),
            topic('recovery.purge', '永久清除页面记录', '明确不再需要时，再移除回收站中的笔记记录。',
                  ['进入回收站，选择目标页面的「永久清除」。', '核对确认窗口列出的范围，再决定是否继续。', '完成后回到普通页面继续工作。'], note='永久清除会移除页面和批注记录，无法靠普通撤销恢复；已索引的原文件仍保留在磁盘上。')),
    ])

if '--guide-only' in sys.argv[1:]:
    target = ROOT / 'Sources/MarginNotes/Resources/Showcase.json'
    catalog = json.loads(target.read_text())
    catalog['guide'] = feature_guide()
    target.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(dict(path=str(target), sections=len(catalog['guide']['sections']),
                         topics=sum(len(s['topics']) for s in catalog['guide']['sections']),
                         legacyPagesPreserved=len(catalog['backup']['workspace']['notes'])), ensure_ascii=False))
    raise SystemExit(0)

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
catalog=dict(version=1,rootID=root_id,scenarios=scenarios,guide=feature_guide(),
             backup=dict(format=1,workspace=dict(schemaVersion=1,notes=notes,pending=[]),assets=assets))
target=ROOT/'Sources/MarginNotes/Resources/Showcase.json'
target.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
(ASSETS/'Libere-Showcase.marginbackup').write_text(json.dumps(catalog['backup'],ensure_ascii=False,separators=(',',':')))
print(json.dumps(dict(rootID=root_id,pages=len(notes),blocks=sum(len(n['blocks']) for n in notes),assets=len(assets),path=str(target)),ensure_ascii=False))
