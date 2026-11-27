import Foundation

public enum FormulaError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
/// Offline LaTeX-to-MathML renderer. Unsupported commands preserve their editable source.
public enum Formula {
    public static func render(_ source: String, display: Bool = true) throws -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$$"), text.hasSuffix("$$"), text.count >= 4 { text = String(text.dropFirst(2).dropLast(2)) }
        else if text.hasPrefix("$"), text.hasSuffix("$"), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        else if (text.hasPrefix("\\(") && text.hasSuffix("\\)")) || (text.hasPrefix("\\[") && text.hasSuffix("\\]")) {
            text = String(text.dropFirst(2).dropLast(2))
        }
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
    mutating func consume(_ command: String) -> Bool {
        let token = Array("\\" + command)
        guard i + token.count <= input.count, Array(input[i..<(i + token.count)]) == token,
              i + token.count == input.count || !input[i + token.count].isLetter else { return false }
        i += token.count; return true
    }
    mutating func sequence(end: Character? = nil) throws -> String {
        depth += 1; defer { depth -= 1 }
        guard depth <= 48 else { throw FormulaError.invalid("公式嵌套过深。") }
        var result = "", styles = 0
        func wrapped(_ text: String, styles: Int) -> String { "<mrow>" + text + String(repeating: "</mstyle>", count: styles) + "</mrow>" }
        func setStyle(display: Bool, level: Int) {
            if styles > 0 { result += "</mstyle>" }
            result += "<mstyle displaystyle=\"\(display ? "true" : "false")\" scriptlevel=\"\(level)\">"; styles = 1
        }
        while let c = peek {
            if c == end { i += 1; return wrapped(result, styles: styles) }
            if c.isWhitespace { i += 1; continue }
            if consume("displaystyle") { setStyle(display: true, level: 0); continue }
            if consume("textstyle") { setStyle(display: false, level: 0); continue }
            if consume("scriptstyle") { setStyle(display: false, level: 1); continue }
            if consume("scriptscriptstyle") { setStyle(display: false, level: 2); continue }
            if c == "}" { throw FormulaError.invalid("多余的右花括号。") }
            var base = try atom(); var sub: String?; var sup: String?; var limits: Bool?
            space()
            while peek != nil {
                if consume("limits") { limits = true; space(); continue }
                if consume("nolimits") { limits = false; space(); continue }
                guard let next = peek, next == "^" || next == "_" else { break }
                i += 1
                if next == "^" {
                    guard sup == nil else { throw FormulaError.invalid("同一表达式出现了重复上标，请用花括号分组。") }
                    sup = try atom()
                } else {
                    guard sub == nil else { throw FormulaError.invalid("同一表达式出现了重复下标，请用花括号分组。") }
                    sub = try atom()
                }
                space()
            }
            let underneath = limits ?? base.hasPrefix("<mo movablelimits=")
            if limits == true { base = base.replacingOccurrences(of: "movablelimits=\"true\"", with: "movablelimits=\"false\"") }
            if let sub, let sup { let tag = underneath ? "munderover" : "msubsup"; base = "<\(tag)>\(base)\(sub)\(sup)</\(tag)>" }
            else if let sub { let tag = underneath ? "munder" : "msub"; base = "<\(tag)>\(base)\(sub)</\(tag)>" }
            else if let sup { let tag = underneath ? "mover" : "msup"; base = "<\(tag)>\(base)\(sup)</\(tag)>" }
            result += base
        }
        guard end == nil else { throw FormulaError.invalid("公式缺少闭合括号。") }
        return wrapped(result, styles: styles)
    }
    mutating func raw() throws -> String {
        space(); guard peek == "{" else { throw FormulaError.invalid("命令后需要 {…}。") }; i += 1
        var level = 1; var text = ""
        while let c = peek {
            i += 1
            if c == "\\", let next = peek, !next.isLetter { text.append(c); text.append(next); i += 1; continue }
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
            if let width = [",":"0.1667", ";":"0.2778", ":":"0.2222", " ":"0.3333", "!":"-0.1667"][String(c)] { return "<mspace width=\"\(width)em\"/>" }
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
        if ["text", "operatorname"].contains(name) {
            let limits = name == "operatorname" && peek == "*"
            if limits { i += 1 }
            let value = try raw()
            var plain = "", escaped = false
            for c in value {
                if escaped { if !"\\{}$%&#_ ".contains(c) { plain.append("\\") }; plain.append(c); escaped = false }
                else if c == "\\" { escaped = true } else { plain.append(c) }
            }
            if escaped { plain.append("\\") }
            // WebKit normalizes MathML token whitespace before CSS white-space
            // applies. NBSP retains TeX's intentional text spacing in the output;
            // the user's stored source is untouched.
            let spaced = plain.replacingOccurrences(of: " ", with: "\u{00A0}")
                .replacingOccurrences(of: "\t", with: String(repeating: "\u{00A0}", count: 4))
            return name == "text" ? "<mtext>\(Formula.escape(spaced))</mtext>"
                : "<mo\(limits ? " movablelimits=\"true\"" : "") mathvariant=\"normal\">\(Formula.escape(plain))</mo>"
        }
        if let variant = ["mathrm":"normal", "mathbf":"bold", "mathit":"italic", "mathbb":"double-struck", "mathcal":"script", "mathscr":"script", "mathfrak":"fraktur", "mathsf":"sans-serif", "mathtt":"monospace", "boldsymbol":"bold-italic", "bm":"bold-italic"][name] {
            return "<mstyle mathvariant=\"\(variant)\">\(try atom())</mstyle>"
        }
        if let mark = ["hat":"^", "widehat":"^", "bar":"¯", "vec":"→", "dot":"˙", "ddot":"¨", "overline":"¯", "tilde":"~", "widetilde":"~"][name] {
            return "<mover accent=\"true\">\(try atom())<mo>\(mark)</mo></mover>"
        }
        if name == "underline" { return "<munder accentunder=\"true\">\(try atom())<mo>¯</mo></munder>" }
        if name == "overset" || name == "underset" {
            let script = try atom(), base = try atom(), tag = name == "overset" ? "mover" : "munder"
            return "<\(tag)>\(base)\(script)</\(tag)>"
        }
        if name == "substack" { let value = try raw(); return try table(value, alignment: "center") }
        if ["left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr"].contains(name) {
            space()
            if peek == "." { i += 1; return "<mrow/>" }
            let delimiter = try atom()
            return delimiter.replacingOccurrences(of: "<mo>", with: "<mo fence=\"true\" stretchy=\"true\">")
        }
        if let width = ["quad":"1", "qquad":"2", "enspace":"0.5", "enskip":"0.5", "thinspace":"0.1667", "medspace":"0.2222", "thickspace":"0.2778", "negthinspace":"-0.1667"][name] {
            return "<mspace width=\"\(width)em\"/>"
        }
        if name == "begin" { return try matrix() }
        if let symbol = Self.symbols[name] {
            if ["ell", "hbar", "hslash"].contains(name) { return "<mi>\(symbol)</mi>" }
            if symbol.unicodeScalars.count == 1, let scalar = symbol.unicodeScalars.first, (0x0370...0x03FF).contains(scalar.value) {
                return "<mi\(name.first?.isUppercase == true ? " mathvariant=\"normal\"" : "")>\(symbol)</mi>"
            }
            let limits = ["sum", "prod", "coprod", "bigcup", "bigcap", "bigoplus", "bigotimes", "bigodot", "biguplus", "bigsqcup", "bigvee", "bigwedge"].contains(name)
            return "<mo\(limits ? " movablelimits=\"true\" largeop=\"true\"" : "")>\(Formula.escape(symbol))</mo>"
        }
        if let text = ["lim":"lim", "max":"max", "min":"min", "sup":"sup", "inf":"inf", "limsup":"lim sup", "liminf":"lim inf", "argmax":"arg max", "argmin":"arg min"][name] {
            return "<mo movablelimits=\"true\" mathvariant=\"normal\">\(text)</mo>"
        }
        if ["sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "arcsin", "arccos", "arctan", "log", "ln", "exp", "det", "dim", "tr", "Tr", "rank", "diag", "arg", "ker", "hom", "deg", "gcd", "Pr"].contains(name) { return "<mi mathvariant=\"normal\">\(name)</mi>" }
        throw FormulaError.invalid("暂不支持命令 \\\(name)，LaTeX 原文会保留。")
    }
    mutating func matrix() throws -> String {
        let env = try raw()
        guard ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "cases", "aligned", "gathered"].contains(env) else { throw FormulaError.invalid("暂不支持 \(env) 环境。") }
        let remaining = String(input[i...]), ending = "\\end{\(env)}"
        guard let end = remaining.range(of: ending) else { throw FormulaError.invalid("缺少 \(ending)。") }
        let contents = String(remaining[..<end.lowerBound])
        guard !contents.contains("\\begin{") else { throw FormulaError.invalid("当前不支持嵌套矩阵。") }
        i += remaining.distance(from: remaining.startIndex, to: end.upperBound)
        let value = try table(contents, alignment: env == "aligned" ? "right left" : env == "cases" ? "left" : "center")
        let fences = ["pmatrix":("(",")"), "bmatrix":("[","]"), "Bmatrix":("{","}"), "vmatrix":("|","|"), "Vmatrix":("‖","‖"), "cases":("{","")]
        if let f = fences[env] {
            return "<mrow><mo fence=\"true\" stretchy=\"true\">\(f.0)</mo>\(value)" + (f.1.isEmpty ? "" : "<mo fence=\"true\" stretchy=\"true\">\(f.1)</mo>") + "</mrow>"
        }
        return env == "smallmatrix" ? "<mstyle scriptlevel=\"1\">\(value)</mstyle>" : value
    }
    mutating func table(_ contents: String, alignment: String) throws -> String {
        let rows = Self.split(contents, separator: "\\\\").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var html = ""
        for row in rows {
            var cells = ""
            for cell in Self.split(row, separator: "&") {
                var parser = Parser(cell); parser.depth = depth
                cells += "<mtd>\(try parser.sequence())</mtd>"
            }
            html += "<mtr>\(cells)</mtr>"
        }
        return "<mtable columnalign=\"\(alignment)\">\(html)</mtable>"
    }
    /// Alignment characters inside groups/text or escaped with a slash are data,
    /// not matrix separators. Row endings obey the same grouping rule.
    private static func split(_ source: String, separator: String) -> [String] {
        let chars = Array(source), token = Array(separator)
        var parts: [String] = [], current = "", index = 0, braces = 0
        while index < chars.count {
            if braces == 0, index + token.count <= chars.count, Array(chars[index..<(index + token.count)]) == token {
                parts.append(current); current = ""; index += token.count; continue
            }
            let c = chars[index]; current.append(c); index += 1
            if c == "\\", index < chars.count, !chars[index].isLetter { current.append(chars[index]); index += 1; continue }
            if c == "{" { braces += 1 }; if c == "}" { braces -= 1 }
        }
        parts.append(current); return parts
    }
    static let symbols: [String:String] = [
        "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ϵ", "varepsilon":"ε", "zeta":"ζ", "eta":"η", "theta":"θ", "iota":"ι", "kappa":"κ", "lambda":"λ", "mu":"μ", "nu":"ν", "xi":"ξ", "pi":"π", "rho":"ρ", "sigma":"σ", "tau":"τ", "upsilon":"υ", "phi":"ϕ", "varphi":"φ", "chi":"χ", "psi":"ψ", "omega":"ω",
        "Gamma":"Γ", "Delta":"Δ", "Theta":"Θ", "Lambda":"Λ", "Xi":"Ξ", "Pi":"Π", "Sigma":"Σ", "Phi":"Φ", "Psi":"Ψ", "Omega":"Ω",
        "sum":"∑", "prod":"∏", "int":"∫", "iint":"∬", "iiint":"∭", "oint":"∮", "infty":"∞", "partial":"∂", "nabla":"∇", "cdot":"⋅", "times":"×", "div":"÷", "pm":"±", "mp":"∓", "le":"≤", "leq":"≤", "ge":"≥", "geq":"≥", "ne":"≠", "neq":"≠", "approx":"≈", "equiv":"≡", "propto":"∝",
        "to":"→", "rightarrow":"→", "leftarrow":"←", "leftrightarrow":"↔", "Rightarrow":"⇒", "Leftrightarrow":"⇔", "implies":"⇒", "iff":"⇔", "in":"∈", "notin":"∉", "subset":"⊂", "subseteq":"⊆", "supset":"⊃", "supseteq":"⊇", "cup":"∪", "cap":"∩", "bigcup":"⋃", "bigcap":"⋂", "coprod":"∐", "emptyset":"∅", "forall":"∀", "exists":"∃", "neg":"¬", "land":"∧", "lor":"∨", "sim":"∼", "simeq":"≃", "cong":"≅", "ldots":"…", "cdots":"⋯", "vdots":"⋮", "ddots":"⋱", "langle":"⟨", "rangle":"⟩", "lbrace":"{", "rbrace":"}", "vert":"|", "lvert":"|", "rvert":"|", "Vert":"‖", "lVert":"‖", "rVert":"‖",
        "oplus":"⊕", "ominus":"⊖", "otimes":"⊗", "oslash":"⊘", "odot":"⊙", "circ":"∘", "bullet":"∙", "ast":"∗", "star":"⋆", "diamond":"⋄",
        "bigoplus":"⨁", "bigotimes":"⨂", "bigodot":"⨀", "biguplus":"⨄", "bigsqcup":"⨆", "bigvee":"⋁", "bigwedge":"⋀",
        "top":"⊤", "bot":"⊥", "perp":"⊥", "intercal":"⊺", "dagger":"†", "ddagger":"‡", "dag":"†", "ddag":"‡", "ell":"ℓ", "hbar":"ℏ", "hslash":"ℏ", "Re":"ℜ", "Im":"ℑ",
        "vartheta":"ϑ", "varrho":"ϱ", "varsigma":"ς", "varpi":"ϖ", "varkappa":"ϰ", "Upsilon":"Υ",
        "mid":"∣", "nmid":"∤", "parallel":"∥", "nparallel":"∦", "ll":"≪", "gg":"≫", "lesssim":"≲", "gtrsim":"≳", "prec":"≺", "succ":"≻", "preceq":"≼", "succeq":"≽", "asymp":"≍", "triangleq":"≜", "coloneqq":"≔", "eqqcolon":"≕",
        "setminus":"∖", "smallsetminus":"∖", "uplus":"⊎", "sqcup":"⊔", "sqcap":"⊓", "nsubseteq":"⊈", "nsupseteq":"⊉", "varnothing":"∅", "nexists":"∄",
        "mapsto":"↦", "longmapsto":"⟼", "longrightarrow":"⟶", "longleftarrow":"⟵", "longleftrightarrow":"⟷", "Leftarrow":"⇐", "Longrightarrow":"⟹", "Longleftarrow":"⟸", "Longleftrightarrow":"⟺", "uparrow":"↑", "downarrow":"↓", "updownarrow":"↕", "nearrow":"↗", "searrow":"↘", "swarrow":"↙", "nwarrow":"↖"
    ]
}
