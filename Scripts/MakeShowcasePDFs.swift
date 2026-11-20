import AppKit
import CoreText

// Original demonstration material; no external paper or lecture is reproduced.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let blue = NSColor(calibratedRed: 0.15, green: 0.34, blue: 0.78, alpha: 1)
let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
let gray = NSColor(calibratedWhite: 0.45, alpha: 1)
let light = NSColor(calibratedRed: 0.94, green: 0.96, blue: 1, alpha: 1)

func text(_ value: String, _ ctx: CGContext, x: CGFloat = 48, top: CGFloat, width: CGFloat = 499,
          height: CGFloat = 80, size: CGFloat = 15, bold: Bool = false, color: NSColor = ink) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 6
    let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    let attributed = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: CGRect(x: x, y: 842 - top - height, width: width, height: height), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, ctx)
}
func box(_ ctx: CGContext, top: CGFloat, height: CGFloat) {
    ctx.setFillColor(light.cgColor); ctx.fill(CGRect(x: 48, y: 842 - top - height, width: 499, height: height))
}
func page(_ ctx: CGContext, number: Int, category: String, title: String, subtitle: String) {
    ctx.beginPDFPage(nil)
    text("Libere  /  " + category, ctx, top: 38, height: 28, size: 10, bold: true, color: blue)
    text(title, ctx, top: 90, height: 75, size: 29, bold: true)
    text(subtitle, ctx, top: 167, height: 60, size: 12, color: gray)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.87, alpha: 1).cgColor)
    ctx.move(to: CGPoint(x: 48, y: 64)); ctx.addLine(to: CGPoint(x: 547, y: 64)); ctx.strokePath()
    text("自制演示材料 · 可在 Libere 中批注", ctx, top: 790, height: 20, size: 10, color: gray)
    text(String(format: "%02d", number), ctx, x: 520, top: 790, width: 27, height: 20, size: 10, color: blue)
}
func document(_ name: String, draw: (CGContext) -> Void) {
    var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(output.appendingPathComponent(name) as CFURL, mediaBox: &bounds,
                            [kCGPDFContextTitle as String: name, kCGPDFContextCreator as String: "Libere 场景展示"] as CFDictionary)!
    draw(context); context.closePDF()
}

document("lecture.pdf") { ctx in
    page(ctx, number: 1, category: "CLASS NOTES", title: "从一次观察开始\n理解贝叶斯更新", subtitle: "概率统计 · 第 05 讲\n课堂目标：区分先验、似然和后验，并解释新证据如何改变判断。")
    text("01  一个问题", ctx, top: 248, height: 32, size: 19, bold: true)
    text("一枚硬币正面出现的概率未知。我们先用 Beta(2, 2) 表达对这一概率的初始判断；随后抛掷 10 次，观察到 8 次正面。应如何更新？", ctx, top: 292, height: 100)
    box(ctx, top: 405, height: 110)
    text("先验  Beta(2, 2)\n新证据  8 次正面 + 2 次反面\n后验  Beta(10, 4)", ctx, x: 65, top: 421, width: 465, height: 90, size: 16, bold: true, color: blue)
    text("02  读懂这个结果", ctx, top: 548, height: 32, size: 19, bold: true)
    text("先验均值是 0.5；后验均值为 10 / 14，约 0.714。这个结果同时包含初始信息和新增观察，不等于仅根据这 10 次观察算出的 0.8。", ctx, top: 592, height: 90)
    text("课堂提问：如果下一次观察是反面，哪些量改变？", ctx, top: 710, height: 35, size: 13, color: blue)
    ctx.endPDFPage()
    page(ctx, number: 2, category: "CLASS NOTES", title: "把公式变成\n能复述的解释", subtitle: "课后复习 · 先解释，再计算\n本页留给自己的推导与检查。")
    text("03  三步复述", ctx, top: 245, height: 32, size: 19, bold: true)
    text("1. 先验：观察之前，对未知概率的表达。\n2. 似然：在某个概率下，观察到这些数据的可能性。\n3. 后验：结合两者之后，对未知概率的新表达。", ctx, top: 290, height: 135)
    box(ctx, top: 448, height: 108)
    text("练习\n再观察到 1 次反面后，后验为 Beta(10, 5)。\n均值 10 / 15 ≈ 0.667，比上一次判断降低。", ctx, x: 65, top: 465, width: 465, height: 88, size: 15, color: blue)
    text("04  自检清单", ctx, top: 592, height: 32, size: 19, bold: true)
    text("能否说清楚“概率的判断”和“观察的频率”之间的区别？\n为什么样本很少时，要保留对结论的不确定性？\n试着把先验换成 Beta(1, 1)，再比较一次。", ctx, top: 634, height: 100)
    ctx.endPDFPage()
}

document("research.pdf") { ctx in
    page(ctx, number: 1, category: "RESEARCH / DEMO", title: "结构化笔记\n与延迟回忆", subtitle: "研究阅读练习 · 虚构材料，不对应已发表论文\n用于演示：资料阅读 → 证据批注 → 研究问题 → 写作提纲。")
    text("研究问题", ctx, top: 245, height: 32, size: 19, bold: true)
    text("把材料摘录与自己的解释放在相邻区域，是否可能帮助学习者在一周后回忆关键概念？本练习把这个问题拆分为笔记结构、复习行为和回忆测验三个部分。", ctx, top: 290, height: 116)
    text("演示设计", ctx, top: 438, height: 32, size: 19, bold: true)
    text("两组模拟学习记录，各 24 条。材料、学习时长与测验题目保持相同；一组使用线性摘录，一组将证据与解释成对放置。结果完全为教学示例构造。", ctx, top: 482, height: 110)
    box(ctx, top: 620, height: 110)
    text("阅读时记录三个层次\n材料实际说了什么？\n这能支持我哪一条论点？还缺什么证据？", ctx, x: 65, top: 638, width: 465, height: 86, size: 15, color: blue)
    ctx.endPDFPage()
    page(ctx, number: 2, category: "RESEARCH / DEMO", title: "从结果到论点\n保留推理的边界", subtitle: "以下均为模拟数值；未进行显著性检验。\n不要把演示结果作为真实研究证据引用。")
    box(ctx, top: 245, height: 163)
    let rows = [["指标", "线性摘录", "证据 + 解释"], ["即时测验均分", "78 / 100", "83 / 100"],
                ["一周后均分", "62 / 100", "71 / 100"], ["模拟记录数", "24", "24"]]
    for (row, values) in rows.enumerated() {
        for (column, value) in values.enumerated() {
            text(value, ctx, x: [65.0, 250, 390][column], top: 264 + CGFloat(row * 29), width: column == 0 ? 170 : 135,
                 height: 25, size: 14, bold: row == 0)
        }
    }
    text("可形成的研究方向", ctx, top: 447, height: 32, size: 19, bold: true)
    text("把“证据旁写自己的解释”作为可检验的操作，而不是笼统比较两种工具。正式研究需要随机分配、预先规定评分方法，并记录复习次数等潜在混杂因素。", ctx, top: 490, height: 110)
    text("写作提醒", ctx, top: 626, height: 32, size: 19, bold: true)
    text("用模拟结果练习图表描述；用“研究设计提案”表达尚待验证的观点。真实论文初稿应替换为实际检索、核验并阅读过的文献和真实数据。", ctx, top: 669, height: 86, size: 14)
    ctx.endPDFPage()
}
print("Created two original, two-page PDF demo attachments in " + output.path)
