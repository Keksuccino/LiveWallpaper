import Foundation

/// A value a wallpaper property holds, or one a condition computes.
public enum PropertyValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
}

/// The `condition` of a wallpaper property: a JavaScript expression Wallpaper Engine evaluates against the current
/// property values to show or hide the property, such as `clock.value == true`, `style.value=='1'` or
/// `effect.value.endsWith('pulse') === true && size.value > 0`. This evaluates the subset wallpapers use: literals,
/// `name.value`, the string methods below, `!`, arithmetic, comparisons (`==` loose like JavaScript, `===` strict),
/// `&&`, `||`, `?:` and calls of functions the caller provides.
public struct PropertyCondition: Equatable, Sendable {
    public let source: String
    private let root: Node

    /// nil for an empty or unparsable expression (Wallpaper Engine shows such a property).
    public init?(_ source: String) {
        var parser = Parser(tokens: Lexer.tokens(source))
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty, let node = parser.expression(), parser.atEnd
        else { return nil }
        self.source = source
        root = node
    }

    /// Whether the property shows. `values` holds every property's value by name; `functions` answers calls such as
    /// `checkPositionVisibility()`. A name that is not there reads as undefined, as in JavaScript.
    public func evaluate(_ values: [String: PropertyValue], functions: [String: () -> PropertyValue] = [:]) -> Bool {
        root.evaluate(Scope(values: values, functions: functions)).truthy
    }

    public static func == (a: PropertyCondition, b: PropertyCondition) -> Bool { a.source == b.source }
}

// MARK: - Evaluation

private struct Scope {
    let values: [String: PropertyValue]
    let functions: [String: () -> PropertyValue]
}

/// A JavaScript value as far as conditions need one.
private enum Value: Sendable {
    case undefined
    case bool(Bool)
    case number(Double)
    case string(String)
    /// A property itself (`name` before `.value`).
    case property(PropertyValue?)

    init(_ v: PropertyValue?) {
        switch v {
        case .bool(let b)?: self = .bool(b)
        case .number(let n)?: self = .number(n)
        case .string(let s)?: self = .string(s)
        case nil: self = .undefined
        }
    }

    var truthy: Bool {
        switch self {
        case .undefined: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .property: return true
        }
    }

    var number: Double {
        switch self {
        case .undefined, .property: return .nan
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? 0 : Double(t) ?? .nan
        }
    }

    var text: String {
        switch self {
        case .undefined: return "undefined"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        case .property: return "[object Object]"
        }
    }

    /// JavaScript's `===`.
    func strictlyEquals(_ o: Value) -> Bool {
        switch (self, o) {
        case (.undefined, .undefined): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        default: return false
        }
    }

    /// JavaScript's `==`: numbers, strings and booleans are compared as numbers unless both are strings.
    func looselyEquals(_ o: Value) -> Bool {
        switch (self, o) {
        case (.undefined, .undefined): return true
        case (.undefined, _), (_, .undefined), (.property, _), (_, .property): return false
        case let (.string(a), .string(b)): return a == b
        default: return number == o.number
        }
    }
}

private indirect enum Node: Sendable {
    case literal(Value)
    case name(String)
    case member(Node, String)
    case call(Node, [Node])
    case unary(String, Node)
    case binary(String, Node, Node)
    case ternary(Node, Node, Node)

    func evaluate(_ scope: Scope) -> Value {
        switch self {
        case .literal(let v):
            return v
        case .name(let name):
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "undefined", "null": return .undefined
            default: return scope.values[name].map { .property($0) } ?? .undefined
            }
        case .member(let base, let field):
            let b = base.evaluate(scope)
            switch (b, field) {
            case (.property(let v), "value"): return Value(v)
            case (.string(let s), "length"): return .number(Double(s.count))
            default: return .undefined
            }
        case .call(let callee, let args):
            let values = args.map { $0.evaluate(scope) }
            switch callee {
            case .name(let name):
                return scope.functions[name].map { Value($0()) } ?? .undefined
            case .member(let base, let method):
                return Self.stringMethod(method, on: base.evaluate(scope), values)
            default:
                return .undefined
            }
        case .unary(let op, let operand):
            let v = operand.evaluate(scope)
            switch op {
            case "!": return .bool(!v.truthy)
            case "-": return .number(-v.number)
            default: return .number(v.number)
            }
        case .binary(let op, let l, let r):
            let a = l.evaluate(scope)
            switch op {
            case "&&": return a.truthy ? r.evaluate(scope) : a
            case "||": return a.truthy ? a : r.evaluate(scope)
            default: break
            }
            let b = r.evaluate(scope)
            switch op {
            case "==": return .bool(a.looselyEquals(b))
            case "!=": return .bool(!a.looselyEquals(b))
            case "===": return .bool(a.strictlyEquals(b))
            case "!==": return .bool(!a.strictlyEquals(b))
            case "<", ">", "<=", ">=":
                if case let (.string(x), .string(y)) = (a, b) {
                    let order = x < y ? -1 : (x == y ? 0 : 1)
                    return .bool(Self.compare(op, Double(order), 0))
                }
                return .bool(Self.compare(op, a.number, b.number))
            case "+":
                if case .string = a { return .string(a.text + b.text) }
                if case .string = b { return .string(a.text + b.text) }
                return .number(a.number + b.number)
            case "-": return .number(a.number - b.number)
            case "*": return .number(a.number * b.number)
            case "/": return .number(a.number / b.number)
            case "%": return .number(a.number.truncatingRemainder(dividingBy: b.number))
            default: return .undefined
            }
        case .ternary(let test, let yes, let no):
            return test.evaluate(scope).truthy ? yes.evaluate(scope) : no.evaluate(scope)
        }
    }

    private static func compare(_ op: String, _ a: Double, _ b: Double) -> Bool {
        switch op {
        case "<": return a < b
        case ">": return a > b
        case "<=": return a <= b
        default: return a >= b
        }
    }

    private static func stringMethod(_ method: String, on base: Value, _ args: [Value]) -> Value {
        guard case .string(let s) = base else { return .undefined }
        let arg = args.first?.text ?? "undefined"
        switch method {
        case "endsWith": return .bool(s.hasSuffix(arg))
        case "startsWith": return .bool(s.hasPrefix(arg))
        case "includes": return .bool(s.contains(arg))
        case "indexOf": return .number(s.range(of: arg).map { Double(s.distance(from: s.startIndex, to: $0.lowerBound)) } ?? -1)
        case "toLowerCase": return .string(s.lowercased())
        case "toUpperCase": return .string(s.uppercased())
        case "trim": return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return .undefined
        }
    }
}

// MARK: - Parsing

private enum Token: Equatable {
    case number(Double)
    case string(String)
    case name(String)
    case symbol(String)
}

private enum Lexer {
    private static let symbols = ["===", "!==", "==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "(", ")", ".", ",",
                                  "+", "-", "*", "/", "%", "?", ":"]

    static func tokens(_ source: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let n = Double(String(chars[i..<j])) else { return nil }
                tokens.append(.number(n))
                i = j
            } else if c == "'" || c == "\"" {
                var j = i + 1
                var text = ""
                while j < chars.count, chars[j] != c {
                    if chars[j] == "\\", j + 1 < chars.count { j += 1 }
                    text.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { return nil }
                tokens.append(.string(text))
                i = j + 1
            } else if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" { j += 1 }
                tokens.append(.name(String(chars[i..<j])))
                i = j
            } else if let symbol = symbols.first(where: { s in
                i + s.count <= chars.count && String(chars[i..<(i + s.count)]) == s
            }) {
                tokens.append(.symbol(symbol))
                i += symbol.count
            } else {
                return nil
            }
        }
        return tokens
    }
}

/// Recursive descent, lowest precedence first: ?:, ||, &&, equality, comparison, + -, * / %, unary, member and call.
private struct Parser {
    private let tokens: [Token]
    private var index = 0
    private var failed = false

    init(tokens: [Token]?) {
        self.tokens = tokens ?? []
        failed = tokens == nil
    }

    var atEnd: Bool { !failed && index == tokens.count }

    mutating func expression() -> Node? {
        guard !failed, let test = binary(0) else { return nil }
        guard take("?") else { return test }
        guard let yes = expression(), take(":"), let no = expression() else { return nil }
        return .ternary(test, yes, no)
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["==", "!=", "===", "!=="], ["<", ">", "<=", ">="],
                                             ["+", "-"], ["*", "/", "%"]]

    private mutating func binary(_ level: Int) -> Node? {
        guard level < Self.levels.count else { return unary() }
        guard var left = binary(level + 1) else { return nil }
        while case .symbol(let op)? = peek, Self.levels[level].contains(op) {
            index += 1
            guard let right = binary(level + 1) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func unary() -> Node? {
        if case .symbol(let op)? = peek, ["!", "-", "+"].contains(op) {
            index += 1
            return unary().map { .unary(op, $0) }
        }
        return postfix()
    }

    private mutating func postfix() -> Node? {
        guard var node = primary() else { return nil }
        while true {
            if take(".") {
                guard case .name(let field)? = next() else { return nil }
                node = .member(node, field)
            } else if take("(") {
                var args: [Node] = []
                if !take(")") {
                    repeat {
                        guard let arg = expression() else { return nil }
                        args.append(arg)
                    } while take(",")
                    guard take(")") else { return nil }
                }
                node = .call(node, args)
            } else {
                return node
            }
        }
    }

    private mutating func primary() -> Node? {
        switch next() {
        case .number(let n)?: return .literal(.number(n))
        case .string(let s)?: return .literal(.string(s))
        case .name(let name)?: return .name(name)
        case .symbol("(")?:
            guard let inner = expression(), take(")") else { return nil }
            return inner
        default: return nil
        }
    }

    private var peek: Token? { index < tokens.count ? tokens[index] : nil }

    private mutating func next() -> Token? {
        defer { index += 1 }
        return peek
    }

    private mutating func take(_ symbol: String) -> Bool {
        guard peek == .symbol(symbol) else { return false }
        index += 1
        return true
    }
}
