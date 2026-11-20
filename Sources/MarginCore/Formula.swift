import Foundation

public enum FormulaError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
/// Small offline LaTeX subset. Unrecognized commands remain editable and show an explicit error.
public enum Formula {
    public static func render(_ source: String, display: Bool = true) throws -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$$"), text.hasSuffix("$$"), text.count >= 4 { text = String(text.dropFirst(2).dropLast(2)) }
        else if text.hasPrefix("$"), text.hasSuffix("$"), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        guard text.count < 12_000 else { throw FormulaError.invalid("请将长公式拆成几个公式块。") }
        var parser = Parser(text)
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display ? "block" : "inline")\">\(try parser.sequence())</math>"
    }
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
private struct Parser {
    var input: [Character]; var i = 0; var depth = 0
    init(_ s: String) { input = Array(s) }
    var peek: Character? { i < input.count ? input[i] : nil }
    mutating func space() { while peek?.isWhitespace == true { i += 1 } }
    mutating func sequence(end: Character? = nil) throws -> String {
        depth += 1; defer { depth -= 1 }
        guard depth <= 48 else { throw FormulaError.invalid("公式嵌套过深。") }
        var result = ""
        while let c = peek {
            if c == end { i += 1; return "<mrow>\(result)</mrow>" }
            if c.isWhitespace { i += 1; continue }
            if c == "}" { throw FormulaError.invalid("多余的右花括号。") }
            var base = try atom(); var sub: String?; var sup: String?
            space()
            while let next = peek, next == "^" || next == "_" {
                i += 1
                if next == "^" { sup = try atom() } else { sub = try atom() }; space()
            }
            if let sub, let sup { base = "<msubsup>\(base)\(sub)\(sup)</msubsup>" }
            else if let sub { base = "<msub>\(base)\(sub)</msub>" }
            else if let sup { base = "<msup>\(base)\(sup)</msup>" }
            result += base
        }
        guard end == nil else { throw FormulaError.invalid("公式缺少闭合括号。") }
        return "<mrow>\(result)</mrow>"
    }
    mutating func raw() throws -> String {
        space(); guard peek == "{" else { throw FormulaError.invalid("命令后需要 {…}。") }; i += 1
        var level = 1; var text = ""
        while let c = peek {
            i += 1
            if c == "{" { level += 1 }
            if c == "}" { level -= 1; if level == 0 { return text } }
            text.append(c)
        }
        throw FormulaError.invalid("缺少右花括号。")
    }
    mutating func atom() throws -> String {
        space(); guard let c = peek else { throw FormulaError.invalid("公式尚未写完。") }; i += 1
        if c == "{" { return try sequence(end: "}") }
        if c == "\\" { return try command() }
        if c == "^" || c == "_" || c == "}" { throw FormulaError.invalid("上标或下标前需要一个表达式。") }
        let tag = c.isNumber ? "mn" : c.isLetter ? "mi" : "mo"
        return "<\(tag)>\(Formula.escape(String(c)))</\(tag)>"
    }
    mutating func command() throws -> String {
        var name = ""
        while let c = peek, c.isLetter { name.append(c); i += 1 }
        if name.isEmpty, let c = peek {
            i += 1
            if [",", ";", ":", " ", "!"].contains(String(c)) { return "<mspace width=\"0.2em\"/>" }
            return "<mo>\(Formula.escape(String(c)))</mo>"
        }
        if ["frac", "dfrac", "tfrac", "binom"].contains(name) {
            let a = try atom(), b = try atom()
            return name == "binom" ? "<mrow><mo>(</mo><mfrac linethickness=\"0\">\(a)\(b)</mfrac><mo>)</mo></mrow>" : "<mfrac>\(a)\(b)</mfrac>"
        }
        if name == "sqrt" {
            space()
            if peek == "[" { i += 1; let n = try sequence(end: "]"); return "<mroot>\(try atom())\(n)</mroot>" }
            return "<msqrt>\(try atom())</msqrt>"
        }
        if ["text", "operatorname"].contains(name) { return "<mtext>\(Formula.escape(try raw()))</mtext>" }
        if let variant = ["mathrm":"normal", "mathbf":"bold", "mathit":"italic", "mathbb":"double-struck", "mathcal":"script"][name] {
            return "<mstyle mathvariant=\"\(variant)\">\(try atom())</mstyle>"
        }
        if let mark = ["hat":"^", "bar":"¯", "vec":"→", "dot":"˙", "ddot":"¨", "overline":"¯", "tilde":"~"][name] {
            return "<mover accent=\"true\">\(try atom())<mo>\(mark)</mo></mover>"
        }
        if ["left", "right", "big", "Big", "limits", "displaystyle"].contains(name) { return "<mrow/>" }
        if name == "quad" || name == "qquad" { return "<mspace width=\"\(name == "quad" ? 1 : 2)em\"/>" }
        if name == "begin" { return try matrix() }
        if let symbol = Self.symbols[name] { return "<mo>\(Formula.escape(symbol))</mo>" }
        if ["sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "lim", "max", "min", "det", "dim", "sup", "inf"].contains(name) { return "<mi mathvariant=\"normal\">\(name)</mi>" }
        throw FormulaError.invalid("暂不支持命令 \\\(name)，LaTeX 原文会保留。")
    }
    mutating func matrix() throws -> String {
        let env = try raw()
        guard ["matrix", "pmatrix", "bmatrix", "vmatrix", "cases", "aligned"].contains(env) else { throw FormulaError.invalid("暂不支持 \(env) 环境。") }
        let remaining = String(input[i...]), ending = "\\end{\(env)}"
        guard let end = remaining.range(of: ending) else { throw FormulaError.invalid("缺少 \(ending)。") }
        let contents = String(remaining[..<end.lowerBound])
        guard !contents.contains("\\begin{") else { throw FormulaError.invalid("当前不支持嵌套矩阵。") }
        i += remaining.distance(from: remaining.startIndex, to: end.upperBound)
        var rows = ""
        for row in contents.components(separatedBy: "\\\\") {
            var cells = ""
            for cell in row.components(separatedBy: "&") { var p = Parser(cell); cells += "<mtd>\(try p.sequence())</mtd>" }
            rows += "<mtr>\(cells)</mtr>"
        }
        let fences = ["pmatrix":("(",")"), "bmatrix":("[","]"), "vmatrix":("|","|"), "cases":("{","")]
        if let f = fences[env] { return "<mrow><mo>\(f.0)</mo><mtable>\(rows)</mtable><mo>\(f.1)</mo></mrow>" }
        return "<mtable>\(rows)</mtable>"
    }
    static let symbols: [String:String] = [
        "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ϵ", "varepsilon":"ε", "zeta":"ζ", "eta":"η", "theta":"θ", "iota":"ι", "kappa":"κ", "lambda":"λ", "mu":"μ", "nu":"ν", "xi":"ξ", "pi":"π", "rho":"ρ", "sigma":"σ", "tau":"τ", "upsilon":"υ", "phi":"ϕ", "varphi":"φ", "chi":"χ", "psi":"ψ", "omega":"ω",
        "Gamma":"Γ", "Delta":"Δ", "Theta":"Θ", "Lambda":"Λ", "Xi":"Ξ", "Pi":"Π", "Sigma":"Σ", "Phi":"Φ", "Psi":"Ψ", "Omega":"Ω",
        "sum":"∑", "prod":"∏", "int":"∫", "iint":"∬", "iiint":"∭", "oint":"∮", "infty":"∞", "partial":"∂", "nabla":"∇", "cdot":"⋅", "times":"×", "div":"÷", "pm":"±", "mp":"∓", "le":"≤", "leq":"≤", "ge":"≥", "geq":"≥", "ne":"≠", "neq":"≠", "approx":"≈", "equiv":"≡", "propto":"∝",
        "to":"→", "rightarrow":"→", "leftarrow":"←", "Rightarrow":"⇒", "Leftrightarrow":"⇔", "in":"∈", "notin":"∉", "subset":"⊂", "subseteq":"⊆", "cup":"∪", "cap":"∩", "emptyset":"∅", "forall":"∀", "exists":"∃", "ldots":"…", "cdots":"⋯", "vdots":"⋮", "ddots":"⋱", "langle":"⟨", "rangle":"⟩", "lbrace":"{", "rbrace":"}", "vert":"|", "Vert":"‖"
    ]
}
