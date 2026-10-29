import Foundation

/// A sampler as the translated code sees it: a texture and a sampler state to call `.sample` with.
struct SamplerBinding: Equatable {
    var texture: String
    var sampler: String
    var is3D: Bool
}

/// A typed, emitted expression.
struct Value {
    var code: String
    var type: HType
    var isLValue = false
    /// The literal's text when this is an integer literal, so it can be written as a float without a cast.
    var intLiteral: String?
    var sampler: SamplerBinding?
}

/// Translates a parsed preset shader to Metal Shading Language, inferring HLSL's types and inserting the implicit
/// conversions HLSL allows and MSL doesn't (vector truncation, scalar-to-vector, int-to-float).
///
/// Representation choices:
/// - User names get prefixes (`v_` locals, `g_` globals, `f_` functions) so they can't collide with MSL names.
/// - Matrices are stored transposed: HLSL `floatRxC(a, b, …)` lists rows and MSL lists columns, so the same text
///   builds the transpose. Then `m[i]` is still row i, and `mul(a, b)` becomes `(b * a)`.
/// - Preset uniforms live in one `MilkUniforms` buffer, `u`. Functions that read uniforms, textures or mutable
///   globals get them as extra parameters, since MSL has no mutable globals or global textures.
struct Emitter {
    let stage: ShaderStage

    private struct FunctionInfo {
        var mangled: String
        var returnType: HType
        var parameters: [Parameter]
        var resources: [String]
    }

    private enum Symbol {
        case local(String, HType)
        case samplerParameter(String, is3D: Bool)
    }

    private struct GlobalInfo {
        var mangled: String
        var type: HType
        var isConstant: Bool
    }

    private var functions: [String: [FunctionInfo]] = [:]
    private var globals: [String: GlobalInfo] = [:]
    /// Mutable globals in declaration order, emitted as locals of the entry point.
    private var mutableGlobals: [(info: GlobalInfo, initializer: Expr?)] = []
    private(set) var userTextures: [String] = []
    private(set) var blurLevel = 0
    private var scopes: [[String: Symbol]] = []
    /// Resources the function being emitted uses: `tex_*`, `smp_main`, mutable globals.
    private var used: Set<String> = []
    private var returnType: HType = .void
    private var inEntryPoint = false

    init(stage: ShaderStage) {
        self.stage = stage
    }

    // MARK: Program

    mutating func emit(_ program: ShaderProgram) throws -> String {
        // HLSL lets a shader write to uniforms (`q25 = q24;`) for the rest of its run; such uniforms become
        // mutable copies.
        for name in Self.assignedNames(program).sorted() {
            guard let (code, type) = Prelude.uniform(name), !code.hasPrefix("M_"), !code.hasPrefix("(") else { continue }
            let info = GlobalInfo(mangled: "g_" + name, type: type, isConstant: false)
            globals[name] = info
            mutableGlobals.append((info, .identifier("__uniform:" + code, line: 0)))
        }
        var top: [String] = []
        for global in program.globals {
            switch global {
            case .declaration(let d):
                top += try globalDeclaration(d)
            case .function(let f):
                if let code = try function(f) { top.append(code) }
            }
        }
        let entry = try entryPoint(program.body)
        return ([Prelude.source(stage: stage)] + top + [entry]).joined(separator: "\n\n") + "\n"
    }

    private mutating func globalDeclaration(_ d: Declaration) throws -> [String] {
        if d.type.isSampler {
            // `sampler sampler_foo;` declares a texture to load; resolve it now so user textures get their slots.
            for declarator in d.declarators { _ = samplerBinding(declarator.name) }
            return []
        }
        var out: [String] = []
        for declarator in d.declarators {
            let name = declarator.name
            // Re-declarations of uniforms the prelude provides (`float4 texsize_noise_lq;`, `float4 _qa;`).
            if Prelude.uniform(name) != nil || name.hasPrefix("texsize_") { continue }
            let type = declarator.arraySize.map { HType.array(d.type, $0) } ?? d.type
            let mangled = "g_" + name
            let constant = d.isConst && declarator.initializer.map(isConstantExpression) == true
            let info = GlobalInfo(mangled: mangled, type: type, isConstant: constant)
            globals[name] = info
            if constant, let initializer = declarator.initializer {
                scopes = [[:]]
                let value = try initialize(initializer, as: type)
                scopes = []
                out.append("constant \(declare(type, mangled)) = \(value);")
            } else {
                mutableGlobals.append((info, declarator.initializer))
            }
        }
        return out
    }

    private func isConstantExpression(_ e: Expr) -> Bool {
        switch e {
        case .number, .boolean: true
        case .unary(_, let a, _), .cast(_, let a, _): isConstantExpression(a)
        case .binary(_, let a, let b, _): isConstantExpression(a) && isConstantExpression(b)
        case .construct(_, let args, _), .list(let args, _): args.allSatisfy(isConstantExpression)
        case .identifier(let name, _): globals[name]?.isConstant == true
        default: false
        }
    }

    private mutating func function(_ f: Function) throws -> String? {
        guard let body = f.body else { return nil }  // Prototypes: MSL needs none, functions come before use.
        let overloads = functions[f.name] ?? []
        let mangled = "f_" + f.name + (overloads.isEmpty ? "" : "_\(overloads.count)")
        scopes = [[:]]
        used = []
        returnType = f.returnType
        inEntryPoint = false
        var parameters: [String] = []
        for p in f.parameters {
            switch p.type {
            case .sampler2D, .sampler3D:
                let is3D = p.type == .sampler3D
                scopes[0][p.name] = .samplerParameter("v_" + p.name, is3D: is3D)
                parameters.append("\(is3D ? "texture3d" : "texture2d")<float> v_\(p.name)_tex")
                parameters.append("sampler v_\(p.name)_smp")
            default:
                let type = p.arraySize.map { HType.array(p.type, $0) } ?? p.type
                scopes[0][p.name] = .local("v_" + p.name, type)
                let reference = p.direction == .in ? "" : "thread "
                parameters.append(p.direction == .in ? declare(type, "v_" + p.name)
                                  : declare(type, "&v_" + p.name, prefix: reference))
            }
        }
        // Register before the body so recursion fails in Metal rather than here; MSL forbids it anyway.
        var info = FunctionInfo(mangled: mangled, returnType: f.returnType, parameters: f.parameters, resources: [])
        let lines = try block(body, indent: 1)
        info.resources = used.sorted()
        functions[f.name, default: []].append(info)
        parameters.append("constant MilkUniforms &u")
        parameters += info.resources.map(resourceParameter)
        scopes = []
        return "static \(f.returnType) \(mangled)(\(parameters.joined(separator: ", "))) {\n\(lines.joined(separator: "\n"))\n}"
    }

    private func resourceParameter(_ name: String) -> String {
        if name == "smp_main" { return "sampler smp_main" }
        if name.hasPrefix("tex_") {
            return (name.hasPrefix("tex_noisevol") ? "texture3d<float> " : "texture2d<float> ") + name
        }
        let info = mutableGlobals.first { $0.info.mangled == name }!.info
        return declare(info.type, "&" + name, prefix: "thread ")
    }

    private mutating func entryPoint(_ body: [Stmt]) throws -> String {
        scopes = [[
            "uv": .local("v_uv", .float(2)), "uv_orig": .local("v_uv_orig", .float(2)),
            "rad": .local("v_rad", .float), "ang": .local("v_ang", .float),
            "hue_shader": .local("v_hue_shader", .float(3)), "ret": .local("v_ret", .float(3)),
        ]]
        used = []
        returnType = .void
        inEntryPoint = true
        var lines = [
            "    float2 v_uv = in.uv;",
            "    float2 v_uv_orig = in.uvOrig;",
            "    float v_rad = length(v_uv_orig - 0.5);",
            "    float v_ang = atan2(v_uv_orig.x - 0.5, v_uv_orig.y - 0.5);",
            "    float3 v_hue_shader = milk_hue(u, v_uv_orig);",
            "    float3 v_ret = float3(0.0);",
        ]
        for (info, initializer) in mutableGlobals {
            let value = try initializer.map { try initialize($0, as: info.type) } ?? zero(info.type)
            lines.append("    \(declare(info.type, info.mangled)) = \(value);")
        }
        lines += try block(body, indent: 1)
        lines.append("    return milk_output(v_ret);")
        let textures = Prelude.standardTextures.enumerated().map { i, t in
            "\(t.hasPrefix("noisevol") ? "texture3d" : "texture2d")<float> tex_\(t) [[texture(\(i))]]"
        } + userTextures.indices.map { i in
            "texture2d<float> tex_user\(i) [[texture(\(Prelude.standardTextures.count + i))]]"
        }
        let parameters = ["MilkVaryings in [[stage_in]]", "constant MilkUniforms &u [[buffer(0)]]",
                          "sampler smp_main [[sampler(0)]]"] + textures
        return "fragment float4 milk_fragment(\(parameters.joined(separator: ",\n                              "))) {\n"
            + lines.joined(separator: "\n") + "\n}"
    }

    /// Names the program assigns to (`x = …`, `x += …`, `x.y = …`, `x++`), to find uniforms it writes.
    private static func assignedNames(_ program: ShaderProgram) -> Set<String> {
        var names: Set<String> = []
        func base(_ e: Expr) -> String? {
            switch e {
            case .identifier(let n, _): n
            case .member(let b, _, _), .index(let b, _, _): base(b)
            default: nil
            }
        }
        func visit(_ e: Expr) {
            switch e {
            case .assign(_, let t, let v, _):
                if let n = base(t) { names.insert(n) }
                visit(t); visit(v)
            case .unary(let op, let a, _):
                if op == "++" || op == "--", let n = base(a) { names.insert(n) }
                visit(a)
            case .postfix(_, let a, _):
                if let n = base(a) { names.insert(n) }
            case .binary(_, let a, let b, _), .comma(let a, let b, _), .index(let a, let b, _):
                visit(a); visit(b)
            case .ternary(let a, let b, let c, _):
                visit(a); visit(b); visit(c)
            case .call(_, let args, _), .construct(_, let args, _), .list(let args, _):
                args.forEach(visit)
            case .cast(_, let a, _), .member(let a, _, _):
                visit(a)
            default:
                break
            }
        }
        func visit(_ s: Stmt) {
            switch s {
            case .block(let b): b.forEach(visit)
            case .declaration(let d): d.declarators.compactMap(\.initializer).forEach(visit)
            case .expression(let e): visit(e)
            case .ifElse(let c, let a, let b): visit(c); visit(a); if let b { visit(b) }
            case .forLoop(let i, let c, let st, let b):
                if let i { visit(i) }; if let c { visit(c) }; if let st { visit(st) }; visit(b)
            case .whileLoop(let c, let b), .doWhile(let b, let c): visit(c); visit(b)
            case .returnValue(let e, _): if let e { visit(e) }
            default: break
            }
        }
        program.body.forEach(visit)
        for case .function(let f) in program.globals { f.body?.forEach(visit) }
        return names
    }

    // MARK: Statements

    private mutating func block(_ statements: [Stmt], indent: Int) throws -> [String] {
        scopes.append([:])
        defer { scopes.removeLast() }
        return try statements.flatMap { try statement($0, indent: indent) }
    }

    private mutating func statement(_ s: Stmt, indent: Int) throws -> [String] {
        let pad = String(repeating: "    ", count: indent)
        switch s {
        case .empty:
            return []
        case .block(let body):
            return ["\(pad){"] + (try block(body, indent: indent + 1)) + ["\(pad)}"]
        case .declaration(let d):
            return try d.declarators.map { declarator in
                guard !d.type.isSampler else { throw ShaderError.unsupported("local sampler variables") }
                let type = declarator.arraySize.map { HType.array(d.type, $0) } ?? d.type
                let initial = try declarator.initializer.map { try initialize($0, as: type) } ?? zero(type)
                let mangled = "v_" + declarator.name
                scopes[scopes.count - 1][declarator.name] = .local(mangled, type)
                return "\(pad)\(d.isConst ? "const " : "")\(declare(type, mangled)) = \(initial);"
            }
        case .expression(let e):
            return ["\(pad)\(try statementExpression(e));"]
        case .ifElse(let c, let then, let otherwise):
            var lines = ["\(pad)if (\(try condition(c))) {"]
            lines += try block([then], indent: indent + 1)
            if let otherwise {
                lines.append("\(pad)} else {")
                lines += try block([otherwise], indent: indent + 1)
            }
            lines.append("\(pad)}")
            return lines
        case .forLoop(let initial, let c, let step, let body):
            scopes.append([:])
            defer { scopes.removeLast() }
            var initText = ""
            if let initial {
                let lines = try statement(initial, indent: 0)
                initText = lines.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "; "))
            }
            let condText = try c.map { try condition($0) } ?? ""
            let stepText = try step.map { try statementExpression($0) } ?? ""
            return ["\(pad)for (\(initText); \(condText); \(stepText)) {"] + (try block([body], indent: indent + 1))
                + ["\(pad)}"]
        case .whileLoop(let c, let body):
            return ["\(pad)while (\(try condition(c))) {"] + (try block([body], indent: indent + 1)) + ["\(pad)}"]
        case .doWhile(let body, let c):
            return ["\(pad)do {"] + (try block([body], indent: indent + 1)) + ["\(pad)} while (\(try condition(c)));"]
        case .returnValue(let e, _):
            if inEntryPoint { return ["\(pad)return milk_output(v_ret);"] }
            guard let e else { return ["\(pad)return;"] }
            return ["\(pad)return \(try convert(try expression(e), to: returnType));"]
        case .breakLoop:
            return ["\(pad)break;"]
        case .continueLoop:
            return ["\(pad)continue;"]
        case .discard:
            return ["\(pad)discard_fragment();"]
        }
    }

    /// An expression used as a statement: no outer parentheses needed.
    private mutating func statementExpression(_ e: Expr) throws -> String {
        let code = try expression(e).code
        if code.hasPrefix("("), code.hasSuffix(")"), balanced(String(code.dropFirst().dropLast())) {
            return String(code.dropFirst().dropLast())
        }
        return code
    }

    private func balanced(_ s: String) -> Bool {
        var depth = 0
        for c in s {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    private mutating func condition(_ e: Expr) throws -> String {
        let v = try expression(e)
        switch v.type {
        case .vector: return "any(bool\(v.type.count)(\(v.code)))"
        default: return v.code
        }
    }

    private mutating func initialize(_ e: Expr, as type: HType) throws -> String {
        if case .list(var items, let line) = e {
            if case .array(let element, let size) = type {
                // `float2 a[2] = { 1, 2, 3, 4 }`: HLSL allows the components flattened.
                if element.count > 1, items.count == size * element.count,
                   items.allSatisfy({ if case .list = $0 { false } else { true } }) {
                    items = stride(from: 0, to: items.count, by: element.count).map { start in
                        Expr.construct(element, Array(items[start..<start + element.count]), line: line)
                    }
                }
                return "{" + (try items.map { try initialize($0, as: element) }.joined(separator: ", ")) + "}"
            }
            return try convert(try construct(type, items, line: line), to: type)
        }
        return try convert(try expression(e), to: type)
    }

    private func zero(_ type: HType) -> String {
        switch type {
        case .array: "{}"
        case .scalar(.bool): "false"
        case .scalar(.float): "0.0"
        case .scalar: "0"
        default: "\(type)(0)"
        }
    }

    private func declare(_ type: HType, _ name: String, prefix: String = "") -> String {
        if case .array(let element, let n) = type {
            return name.hasPrefix("&") ? "\(prefix)\(element) (\(name))[\(n)]" : "\(prefix)\(element) \(name)[\(n)]"
        }
        return "\(prefix)\(type) \(name)"
    }

    // MARK: Expressions

    private func lookup(_ name: String) -> Symbol? {
        for scope in scopes.reversed() { if let s = scope[name] { return s } }
        return nil
    }

    mutating func expression(_ e: Expr) throws -> Value {
        switch e {
        case .number(let text, let line):
            return try number(text, line: line)
        case .boolean(let b, _):
            return Value(code: b ? "true" : "false", type: .bool)
        case .identifier(let name, let line):
            return try identifier(name, line: line)
        case .unary(let op, let operand, let line):
            let v = try expression(operand)
            guard v.type.isNumeric else { throw ShaderError.semantic("\(op) needs a number", line) }
            switch op {
            case "-" where v.type.isMatrix: return Value(code: "(\(v.code) * -1.0)", type: v.type)
            case "-": return Value(code: "(-\(v.code))", type: v.type, intLiteral: v.intLiteral.map { "-" + $0 })
            case "+": return v
            case "!":
                if case .vector(_, let n) = v.type { return Value(code: "(\(v.code) == \(v.type)(0))", type: .vector(.bool, n)) }
                return Value(code: "(!\(v.code))", type: .bool)
            case "~": return Value(code: "(~\(v.code))", type: v.type)
            default:
                guard v.isLValue else { throw ShaderError.semantic("\(op) needs a variable", line) }
                return Value(code: "(\(op)\(v.code))", type: v.type)
            }
        case .postfix(let op, let operand, let line):
            let v = try expression(operand)
            guard v.isLValue else { throw ShaderError.semantic("\(op) needs a variable", line) }
            return Value(code: "(\(v.code)\(op))", type: v.type)
        case .binary(let op, let a, let b, let line):
            return try binary(op, a, b, line: line)
        case .assign(let op, let target, let value, let line):
            return try assign(op, target, value, line: line)
        case .ternary(let c, let a, let b, let line):
            let cv = try expression(c)
            let av = try expression(a), bv = try expression(b)
            guard let type = unify([av.type, bv.type]) else { throw ShaderError.semantic("mismatched ?: branches", line) }
            let ac = try convert(av, to: type), bc = try convert(bv, to: type)
            if case .vector(_, let n) = cv.type {
                // A vector condition picks per component.
                let vt = HType.vector(type.scalarKind ?? .float, n)
                let cond = try convert(cv, to: .vector(.bool, n))
                return Value(code: "select(\(try convert(bv, to: vt)), \(try convert(av, to: vt)), \(cond))", type: vt)
            }
            return Value(code: "(\(cv.code) ? \(ac) : \(bc))", type: type)
        case .call(let name, let args, let line):
            return try call(name, args, line: line)
        case .construct(let type, let args, let line):
            return try construct(type, args, line: line)
        case .cast(let type, let operand, _):
            let v = try expression(operand)
            return Value(code: try convert(v, to: type, explicit: true), type: type)
        case .member(let base, let name, let line):
            return try member(base, name, line: line)
        case .index(let base, let index, let line):
            let b = try expression(base)
            let i = try expression(index)
            let indexCode = i.type.scalarKind == .float ? "int(\(i.code))" : i.code
            let type: HType
            switch b.type {
            case .vector(let k, _): type = .scalar(k)
            case .matrix(let k, _, let c): type = c == 1 ? .scalar(k) : .vector(k, c)
            case .array(let t, _): type = t
            default: throw ShaderError.semantic("can't index \(b.type)", line)
            }
            return Value(code: "\(b.code)[\(indexCode)]", type: type, isLValue: b.isLValue)
        case .list(_, let line):
            throw ShaderError.semantic("unexpected { … } list", line)
        case .comma(let a, let b, _):
            let av = try expression(a), bv = try expression(b)
            return Value(code: "(\(av.code), \(bv.code))", type: bv.type)
        }
    }

    private func number(_ text: String, line: Int) throws -> Value {
        var t = text
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            guard let v = Int(t.dropFirst(2), radix: 16) else { throw ShaderError.syntax("bad number \(text)", line) }
            return Value(code: "\(v)", type: .int, intLiteral: "\(v)")
        }
        let isFloat = t.contains(".") || t.contains("e") || t.contains("E") || t.hasSuffix("f") || t.hasSuffix("F")
            || t.hasSuffix("h") || t.hasSuffix("H")
        while let last = t.last, "fFhHlLuU".contains(last) { t.removeLast() }
        if isFloat {
            if t.hasPrefix(".") { t = "0" + t }
            if t.hasSuffix(".") { t += "0" }
            guard Double(t) != nil else { throw ShaderError.syntax("bad number \(text)", line) }
            return Value(code: t, type: .float)
        }
        // Leading zeros would read as octal in MSL; HLSL reads them as decimal.
        let decimal = String(Int(t) ?? 0)
        return Value(code: decimal, type: .int, intLiteral: decimal)
    }

    private mutating func identifier(_ name: String, line: Int) throws -> Value {
        if name.hasPrefix("__uniform:") {
            let code = String(name.dropFirst("__uniform:".count))
            return Value(code: code, type: Prelude.uniformType(code: code))
        }
        if let symbol = lookup(name) {
            switch symbol {
            case .local(let mangled, let type):
                return Value(code: mangled, type: type, isLValue: true)
            case .samplerParameter(let mangled, let is3D):
                return Value(code: mangled, type: is3D ? .sampler3D : .sampler2D,
                             sampler: SamplerBinding(texture: mangled + "_tex", sampler: mangled + "_smp", is3D: is3D))
            }
        }
        if let g = globals[name] {
            if !g.isConstant { used.insert(g.mangled) }
            return Value(code: g.mangled, type: g.type, isLValue: !g.isConstant)
        }
        if let (code, type) = Prelude.uniform(name) {
            return Value(code: code, type: type)
        }
        if name.hasPrefix("texsize_") {
            let textureName = String(name.dropFirst("texsize_".count))
            if let i = userTextures.firstIndex(of: textureName) { return Value(code: "u.texsize_user[\(i)]", type: .float(4)) }
            if userTextures.count < Prelude.maxUserTextures {
                userTextures.append(textureName)
                return Value(code: "u.texsize_user[\(userTextures.count - 1)]", type: .float(4))
            }
        }
        if let binding = samplerBinding(name) {
            return Value(code: name, type: binding.is3D ? .sampler3D : .sampler2D, sampler: binding)
        }
        throw ShaderError.semantic("unknown name \(name)", line)
    }

    /// `sampler_[fw_|fc_|pw_|pc_]NAME`: the texture and the sampler state its prefix picks.
    mutating func samplerBinding(_ name: String) -> SamplerBinding? {
        guard name.hasPrefix("sampler_") else { return nil }
        var rest = String(name.dropFirst("sampler_".count))
        var state: String?
        for prefix in ["fw_", "fc_", "pw_", "pc_"] where rest.hasPrefix(prefix) {
            state = "milk_" + prefix.dropLast()
            rest = String(rest.dropFirst(3))
        }
        guard !rest.isEmpty else { return nil }
        let texture: String
        var defaultState = "milk_fw"
        switch rest {
        case "main":
            // Unprefixed sampler_main: in the warp shader the preset's bTexWrap picks wrap or clamp (the renderer
            // binds it as sampler 0), as before. In the composite it is filtered and wrapping like MilkDrop 2's
            // other unprefixed samplers: presets with bTexWrap=0 that read it outside 0…1 rely on that
            // (Sparkle/Mass Circles/suksma - dotes hostile undertake - offx). Wrapping in the warp too fixed 4 more
            // presets but turned 4 that drew into black frames, so the warp keeps bTexWrap.
            texture = "tex_main"
            if stage == .warp {
                if state == nil { used.insert("smp_main") }
                defaultState = "smp_main"
            }
        case "blur1", "blur2", "blur3":
            texture = "tex_" + rest
            defaultState = "milk_fc"
            blurLevel = max(blurLevel, Int(String(rest.last!))!)
        case let t where Prelude.standardTextures.contains(t):
            texture = "tex_" + t
        default:
            guard let i = userTextures.firstIndex(of: rest) ?? appendUserTexture(rest) else { return nil }
            texture = "tex_user\(i)"
        }
        used.insert(texture)
        return SamplerBinding(texture: texture, sampler: state ?? defaultState, is3D: rest.hasPrefix("noisevol"))
    }

    private mutating func appendUserTexture(_ name: String) -> Int? {
        guard userTextures.count < Prelude.maxUserTextures else { return nil }
        userTextures.append(name)
        return userTextures.count - 1
    }

    private mutating func binary(_ op: String, _ a: Expr, _ b: Expr, line: Int) throws -> Value {
        let l = try expression(a), r = try expression(b)
        guard l.type.isNumeric, r.type.isNumeric else { throw ShaderError.semantic("\(op) needs numbers", line) }
        switch op {
        case "&&", "||":
            return Value(code: "(\(try truth(l)) \(op) \(try truth(r)))", type: .bool)
        case "==", "!=", "<", ">", "<=", ">=":
            guard let type = unify([l.type, r.type]) else { throw ShaderError.semantic("can't compare \(l.type) and \(r.type)", line) }
            let result: HType = type.count == 1 ? .bool : .vector(.bool, type.count)
            return Value(code: "(\(try operand(l, type)) \(op) \(try operand(r, type)))", type: result)
        case "&", "|", "^", "<<", ">>":
            let type = unify([l.type, r.type])?.with(.int) ?? .int
            return Value(code: "(\(try convert(l, to: type)) \(op) \(try convert(r, to: type)))", type: type)
        default:
            guard var type = unify([l.type, r.type]) else {
                throw ShaderError.semantic("can't combine \(l.type) and \(r.type) with \(op)", line)
            }
            if type.scalarKind == .bool { type = type.with(.int) }
            if type.isMatrix, l.type.isMatrix, r.type.isMatrix, op == "*" || op == "/" {
                return Value(code: "milk_\(op == "*" ? "cmul" : "cdiv")(\(try convert(l, to: type)), \(try convert(r, to: type)))",
                             type: type)
            }
            if case .matrix(_, let rows, let cols) = type, op == "+" || op == "-", l.type.count == 1 || r.type.count == 1 {
                // MSL has no matrix ± scalar; spell the scalar out as a full matrix (rows are the stored columns).
                func full(_ v: Value) throws -> String {
                    guard v.type.count == 1 else { return v.code }
                    let s = try convert(v, to: .float)
                    return "\(type)(\(Array(repeating: "float\(cols)(\(s))", count: rows).joined(separator: ", ")))"
                }
                return Value(code: "(\(try full(l)) \(op) \(try full(r)))", type: type)
            }
            if op == "%", type.scalarKind == .float {
                return Value(code: "fmod(\(try convert(l, to: type)), \(try convert(r, to: type)))", type: type)
            }
            if op == "/", type.scalarKind != .float, l.intLiteral != nil, r.intLiteral != nil {
                // Constant integer division: keep HLSL's truncation.
                return Value(code: "(\(l.code) / \(r.code))", type: type)
            }
            if op == "/", type.scalarKind == .float {
                return Value(code: "milk_div(\(try convert(l, to: type)), \(try convert(r, to: type)))", type: type)
            }
            return Value(code: "(\(try operand(l, type)) \(op) \(try operand(r, type)))", type: type)
        }
    }

    /// An operand of a componentwise operation: scalars stay scalar (MSL broadcasts them), vectors take `type`'s
    /// size, and the kind becomes `type`'s.
    private func operand(_ v: Value, _ type: HType) throws -> String {
        guard let kind = type.scalarKind else { return v.code }
        if v.type.count == 1 { return try convert(v, to: .scalar(kind)) }
        return try convert(v, to: type)
    }

    private func truth(_ v: Value) throws -> String {
        if case .vector(_, let n) = v.type { return "any(bool\(n)(\(v.code)))" }
        return v.code
    }

    private mutating func assign(_ op: String, _ target: Expr, _ value: Expr, line: Int) throws -> Value {
        let t = try expression(target)
        guard t.isLValue else { throw ShaderError.semantic("can't assign to this", line) }
        if case .list = value {
            return Value(code: "(\(t.code) = \(try initialize(value, as: t.type)))", type: t.type)
        }
        let v = try expression(value)
        switch op {
        case "=":
            return Value(code: "(\(t.code) = \(try convert(v, to: t.type)))", type: t.type)
        case "%=" where t.type.scalarKind == .float:
            return Value(code: "(\(t.code) = fmod(\(t.code), \(try convert(v, to: t.type))))", type: t.type)
        case "/=" where t.type.scalarKind == .float && !t.type.isMatrix:
            return Value(code: "(\(t.code) = milk_div(\(t.code), \(try convert(v, to: t.type))))", type: t.type)
        case "*=" where t.type.isMatrix && v.type.isMatrix, "/=" where t.type.isMatrix && v.type.isMatrix:
            let f = op == "*=" ? "milk_cmul" : "milk_cdiv"
            return Value(code: "(\(t.code) = \(f)(\(t.code), \(try convert(v, to: t.type))))", type: t.type)
        default:
            let rhs = try operand(v, t.type)
            return Value(code: "(\(t.code) \(op) \(rhs))", type: t.type)
        }
    }

    private mutating func member(_ base: Expr, _ name: String, line: Int) throws -> Value {
        let b = try expression(base)
        switch b.type {
        case .scalar(let k):
            guard name.allSatisfy({ $0 == "x" || $0 == "r" }), (1...4).contains(name.count) else {
                throw ShaderError.semantic("bad swizzle .\(name) on a scalar", line)
            }
            if name.count == 1 { return Value(code: b.code, type: b.type, isLValue: b.isLValue) }
            return Value(code: "\(HType.vector(k, name.count))(\(b.code))", type: .vector(k, name.count))
        case .vector(let k, let n):
            let xyzw = "xyzw", rgba = "rgba"
            let set = name.allSatisfy({ xyzw.contains($0) }) ? xyzw : (name.allSatisfy({ rgba.contains($0) }) ? rgba : "")
            guard !set.isEmpty, (1...4).contains(name.count),
                  name.allSatisfy({ c in set.firstIndex(of: c).map { set.distance(from: set.startIndex, to: $0) < n } == true })
            else { throw ShaderError.semantic("bad swizzle .\(name) on \(b.type)", line) }
            let type: HType = name.count == 1 ? .scalar(k) : .vector(k, name.count)
            let unique = Set(name).count == name.count
            return Value(code: "\(parenthesized(b.code)).\(name)", type: type, isLValue: b.isLValue && unique)
        case .matrix(let k, _, _):
            // `._m01` (zero-based) or `._12` (one-based): row, column.
            let digits = Array(name.dropFirst(name.hasPrefix("_m") ? 2 : 1))
            guard name.hasPrefix("_"), digits.count == 2, let r = Int(String(digits[0])), let c = Int(String(digits[1])) else {
                throw ShaderError.semantic("bad matrix member .\(name)", line)
            }
            let base = name.hasPrefix("_m") ? 0 : 1
            return Value(code: "\(b.code)[\(r - base)][\(c - base)]", type: .scalar(k), isLValue: b.isLValue)
        default:
            throw ShaderError.semantic("no member .\(name) on \(b.type)", line)
        }
    }

    /// `code` wrapped in parentheses unless it's already a single term (a name, member, index, call or
    /// parenthesised group), so a member access can follow it.
    private func parenthesized(_ code: String) -> String {
        var depth = 0
        for c in code {
            if c == "(" || c == "[" { depth += 1; continue }
            if c == ")" || c == "]" { depth -= 1; continue }
            if depth == 0, !(c.isLetter || c.isNumber || c == "_" || c == ".") { return "(\(code))" }
        }
        return code
    }

    // MARK: Constructors and calls

    private mutating func construct(_ type: HType, _ args: [Expr], line: Int) throws -> Value {
        guard let kind = type.scalarKind else { throw ShaderError.semantic("can't construct \(type)", line) }
        let values = try args.map { try expression($0) }
        if values.count == 1, values[0].type.count >= type.count {
            return Value(code: try convert(values[0], to: type, explicit: true), type: type)
        }
        var remaining = type.count
        var parts: [String] = []
        for v in values {
            guard remaining > 0 else { break }
            let n = min(v.type.count, remaining)
            let target: HType = n == 1 ? .scalar(kind) : .vector(kind, n)
            if v.type.isMatrix {
                parts.append(v.code)
            } else {
                parts.append(try convert(v, to: target))
            }
            remaining -= n
        }
        return Value(code: "\(type)(\(parts.joined(separator: ", ")))", type: type)
    }

    private mutating func call(_ name: String, _ args: [Expr], line: Int) throws -> Value {
        if let overloads = functions[name] {
            return try userCall(name, overloads, args, line: line)
        }
        return try intrinsic(name, args, line: line)
    }

    private mutating func userCall(_ name: String, _ overloads: [FunctionInfo], _ args: [Expr], line: Int) throws -> Value {
        let candidates = overloads.filter { $0.parameters.count == args.count }
        guard !candidates.isEmpty else {
            throw ShaderError.semantic("\(name) takes \(overloads[0].parameters.count) arguments", line)
        }
        let values = try args.map { try expression($0) }
        // The first overload whose parameter types match exactly, else the first with the right count.
        let f = candidates.first { c in zip(c.parameters, values).allSatisfy { $0.type == $1.type } } ?? candidates[0]
        var parts: [String] = []
        for (p, v) in zip(f.parameters, values) {
            if p.type.isSampler {
                guard let s = v.sampler else { throw ShaderError.semantic("\(name) needs a sampler", line) }
                parts += [s.texture, s.sampler]
                if s.texture.hasPrefix("tex_") { used.insert(s.texture) }
                if s.sampler == "smp_main" { used.insert("smp_main") }
            } else if p.direction != .in {
                parts.append(v.code)
            } else {
                parts.append(try convert(v, to: p.arraySize.map { HType.array(p.type, $0) } ?? p.type))
            }
        }
        parts.append("u")
        parts += f.resources
        used.formUnion(f.resources)
        return Value(code: "\(f.mangled)(\(parts.joined(separator: ", ")))", type: f.returnType)
    }

    private static let unaryMath: [String: String] = [
        "abs": "abs", "acos": "acos", "asin": "asin", "atan": "atan", "ceil": "ceil", "cos": "cos", "cosh": "cosh",
        "exp": "exp", "exp2": "exp2", "floor": "floor", "frac": "fract", "log": "log", "log10": "log10",
        "log2": "log2", "round": "rint", "rsqrt": "rsqrt", "saturate": "saturate", "sign": "sign", "sin": "sin",
        "sinh": "sinh", "sqrt": "sqrt", "tan": "tan", "tanh": "tanh", "trunc": "trunc", "ddx": "dfdx", "ddy": "dfdy",
        "fwidth": "fwidth", "isnan": "isnan", "isinf": "isinf", "isfinite": "isfinite",
    ]
    /// Functions whose Direct3D 9 instructions (`log`, `pow`) use the absolute value of the first operand. (`rsq`
    /// does too, but see `intrinsic`: sqrt and rsqrt are left alone.)
    static let absoluteFirstOperand: Set<String> = ["log", "log2", "log10", "pow"]
    private static let binaryMath: [String: String] = [
        "atan2": "atan2", "fmod": "fmod", "max": "max", "min": "min", "pow": "pow", "step": "step",
        "reflect": "reflect", "ldexp": "ldexp",
    ]
    private static let ternaryMath: [String: String] = [
        "clamp": "clamp", "lerp": "mix", "smoothstep": "smoothstep", "faceforward": "faceforward",
    ]

    private mutating func intrinsic(_ name: String, _ args: [Expr], line: Int) throws -> Value {
        func arity(_ n: Int) throws {
            guard args.count == n else { throw ShaderError.semantic("\(name) takes \(n) arguments", line) }
        }
        if name.hasPrefix("tex") { return try textureCall(name, args, line: line) }
        let values = try args.map { try expression($0) }
        /// Componentwise: every argument converted to one type. Math functions work in float.
        func componentwise(_ mslName: String, keepInt: Bool = false) throws -> Value {
            guard var type = unify(values.map(\.type)) else { throw ShaderError.semantic("\(name): mismatched arguments", line) }
            if !keepInt || type.scalarKind == .bool { type = type.with(.float) }
            var parts = try values.map { try convert($0, to: type) }
            // MilkDrop's shaders run as Direct3D 9 shader model 2/3, whose log and pow instructions take the
            // absolute value of their (first) operand: pow(-2, 0.5) is 1.41, not NaN, and a NaN written to the 8-bit
            // feedback is 0 (black). D3D9's rsq does the same, but doing it for sqrt/rsqrt here turned two presets
            // that draw now (Fractal/Nested Circle/… soft death) black, so sqrt and rsqrt keep IEEE semantics.
            if Self.absoluteFirstOperand.contains(name), !parts.isEmpty { parts[0] = "abs(\(parts[0]))" }
            let result = ["isnan", "isinf", "isfinite"].contains(name) ? type.with(.bool) : type
            return Value(code: "\(mslName)(\(parts.joined(separator: ", ")))", type: result)
        }
        switch name {
        case _ where Self.unaryMath[name] != nil:
            try arity(1)
            return try componentwise(Self.unaryMath[name]!, keepInt: ["abs", "sign"].contains(name))
        case _ where Self.binaryMath[name] != nil:
            try arity(2)
            return try componentwise(Self.binaryMath[name]!, keepInt: ["max", "min"].contains(name))
        case _ where Self.ternaryMath[name] != nil:
            try arity(3)
            return try componentwise(Self.ternaryMath[name]!, keepInt: name == "clamp")
        case "degrees", "radians":
            try arity(1)
            let v = try componentwise("")
            return Value(code: "(\(v.code) * \(name == "degrees" ? "57.29577951308232" : "0.017453292519943295"))", type: v.type)
        case "dot":
            try arity(2)
            guard let type = unify(values.map(\.type))?.with(.float) else { throw ShaderError.semantic("dot: mismatched", line) }
            if type.count == 1 { return Value(code: "(\(try convert(values[0], to: type)) * \(try convert(values[1], to: type)))", type: .float) }
            return Value(code: "dot(\(try convert(values[0], to: type)), \(try convert(values[1], to: type)))", type: .float)
        case "length", "normalize":
            try arity(1)
            let type = values[0].type.with(.float)
            if type.count == 1 { return Value(code: "\(name == "length" ? "abs" : "sign")(\(try convert(values[0], to: type)))", type: type) }
            return Value(code: "\(name)(\(try convert(values[0], to: type)))", type: name == "length" ? .float : type)
        case "distance":
            try arity(2)
            guard let type = unify(values.map(\.type))?.with(.float) else { throw ShaderError.semantic("distance: mismatched", line) }
            if type.count == 1 { return Value(code: "abs(\(try convert(values[0], to: type)) - \(try convert(values[1], to: type)))", type: .float) }
            return Value(code: "distance(\(try convert(values[0], to: type)), \(try convert(values[1], to: type)))", type: .float)
        case "cross":
            try arity(2)
            return Value(code: "cross(\(try convert(values[0], to: .float(3))), \(try convert(values[1], to: .float(3))))", type: .float(3))
        case "refract":
            try arity(3)
            guard let type = unify([values[0].type, values[1].type])?.with(.float) else { throw ShaderError.semantic("refract", line) }
            return Value(code: "refract(\(try convert(values[0], to: type)), \(try convert(values[1], to: type)), \(try convert(values[2], to: .float)))", type: type)
        case "any", "all":
            try arity(1)
            if values[0].type.count == 1 { return Value(code: "bool(\(values[0].code))", type: .bool) }
            return Value(code: "\(name)(bool\(values[0].type.count)(\(values[0].code)))", type: .bool)
        case "mul":
            try arity(2)
            return try multiply(values[0], values[1], line: line)
        case "transpose":
            try arity(1)
            guard case .matrix(let k, let r, let c) = values[0].type else { throw ShaderError.semantic("transpose needs a matrix", line) }
            return Value(code: "transpose(\(values[0].code))", type: .matrix(k, c, r))
        case "determinant":
            try arity(1)
            return Value(code: "determinant(\(values[0].code))", type: .float)
        case "modf":
            try arity(2)
            guard values[1].isLValue else { throw ShaderError.semantic("modf needs a variable", line) }
            let type = values[0].type.with(.float)
            return Value(code: "milk_modf(\(try convert(values[0], to: type)), \(values[1].code))", type: type)
        case "sincos":
            try arity(3)
            guard values[1].isLValue, values[2].isLValue else { throw ShaderError.semantic("sincos needs variables", line) }
            let type = values[0].type.with(.float)
            return Value(code: "milk_sincos(\(try convert(values[0], to: type)), \(values[1].code), \(values[2].code))", type: .void)
        case "clip":
            try arity(1)
            return Value(code: "milk_clip(\(values[0].code))", type: .void)
        default:
            throw ShaderError.semantic("unknown function \(name)", line)
        }
    }

    /// HLSL `mul(a, b)` over transposed matrices is `b * a` in MSL.
    private func multiply(_ a: Value, _ b: Value, line: Int) throws -> Value {
        switch (a.type, b.type) {
        case (.matrix(let k, let r, let c), .vector):
            // mul(M, v): v is a column of M's width; the result has M's height.
            let v = try convert(b, to: .float(c))
            return Value(code: "(\(v) * \(a.code))", type: r == 1 ? .scalar(k) : .vector(k, r))
        case (.vector, .matrix(let k, let r, let c)):
            // mul(v, M): v is a row of M's height; the result has M's width.
            let v = try convert(a, to: .float(r))
            return Value(code: "(\(b.code) * \(v))", type: c == 1 ? .scalar(k) : .vector(k, c))
        case (.matrix(let k, let r, _), .matrix(_, _, let c)):
            return Value(code: "(\(b.code) * \(a.code))", type: .matrix(k, r, c))
        case (.vector, .vector):
            guard let type = unify([a.type, b.type])?.with(.float) else { throw ShaderError.semantic("mul: mismatched", line) }
            return Value(code: "dot(\(try convert(a, to: type)), \(try convert(b, to: type)))", type: .float)
        default:
            guard let type = unify([a.type, b.type]) else { throw ShaderError.semantic("mul: mismatched", line) }
            return Value(code: "(\(try operand(a, type)) * \(try operand(b, type)))", type: type)
        }
    }

    private mutating func textureCall(_ name: String, _ args: [Expr], line: Int) throws -> Value {
        guard let first = args.first else { throw ShaderError.semantic("\(name) needs a sampler", line) }
        let s = try expression(first)
        guard let binding = s.sampler else { throw ShaderError.semantic("\(name) needs a sampler", line) }
        let rest = try args.dropFirst().map { try expression($0) }
        let coordinate: HType = binding.is3D ? .float(3) : .float(2)
        let t = binding.texture, smp = binding.sampler
        func coords(_ v: Value) throws -> String { try convert(v, to: coordinate) }
        func swizzled(_ v: Value, _ n: Int) throws -> String {
            let v4 = try convert(v, to: .float(4))
            return "\(parenthesized(v4)).\(String("xyz".prefix(n)))"
        }
        let n = binding.is3D ? 3 : 2
        let code: String
        switch name {
        case "tex2D", "tex3D", "texCUBE", "tex1D":
            guard rest.count >= 1 else { throw ShaderError.semantic("\(name) needs coordinates", line) }
            code = "\(t).sample(\(smp), \(try coords(rest[0])))"
        case "tex2Dlod", "tex3Dlod":
            guard rest.count == 1 else { throw ShaderError.semantic("\(name) takes 2 arguments", line) }
            let c = try convert(rest[0], to: .float(4))
            code = "\(t).sample(\(smp), \(parenthesized(c)).\(String("xyz".prefix(n))), level(\(parenthesized(c)).w))"
        case "tex2Dbias", "tex3Dbias":
            guard rest.count == 1 else { throw ShaderError.semantic("\(name) takes 2 arguments", line) }
            let c = try convert(rest[0], to: .float(4))
            code = "\(t).sample(\(smp), \(parenthesized(c)).\(String("xyz".prefix(n))), bias(\(parenthesized(c)).w))"
        case "tex2Dproj", "tex3Dproj":
            guard rest.count == 1 else { throw ShaderError.semantic("\(name) takes 2 arguments", line) }
            let c = try convert(rest[0], to: .float(4))
            code = "\(t).sample(\(smp), \(try swizzled(rest[0], n)) / \(parenthesized(c)).w)"
        case "tex2Dgrad":
            guard rest.count == 3, !binding.is3D else { throw ShaderError.semantic("\(name) takes 4 arguments", line) }
            code = "\(t).sample(\(smp), \(try coords(rest[0])), gradient2d(\(try convert(rest[1], to: .float(2))), \(try convert(rest[2], to: .float(2)))))"
        default:
            throw ShaderError.semantic("unknown function \(name)", line)
        }
        return Value(code: code, type: .float(4))
    }

    // MARK: Types

    /// The common type of componentwise operands: the widest kind; vectors truncate to the shortest (as HLSL
    /// does); scalars broadcast.
    func unify(_ types: [HType]) -> HType? {
        guard types.allSatisfy(\.isNumeric) else { return nil }
        let kind = types.compactMap(\.scalarKind).max() ?? .float
        if let m = types.first(where: \.isMatrix) {
            return m.with(kind)
        }
        let sizes = types.compactMap { t -> Int? in if case .vector(_, let n) = t { n } else { nil } }
        if let n = sizes.min() { return .vector(kind, n) }
        return .scalar(kind)
    }

    /// Converts `v` to `type` with HLSL's implicit rules (`explicit` also allows casts that HLSL requires).
    func convert(_ v: Value, to type: HType, explicit: Bool = false) throws -> String {
        if v.type == type { return v.code }
        switch (v.type, type) {
        case (.scalar, .scalar(let k)):
            if k == .float, let literal = v.intLiteral { return literal + ".0" }
            return "\(k.name)(\(v.code))"
        case (.scalar, .vector(let k, _)):
            let scalar = try convert(v, to: .scalar(k))
            return "\(type)(\(scalar))"
        case (.vector(let k1, let n1), .vector(let k2, let n2)):
            var code = v.code
            if n2 < n1 { code = "\(parenthesized(code)).\(String("xyzw".prefix(n2)))" }
            if n2 > n1 {
                return "\(type)(\(code)\(String(repeating: ", 0", count: n2 - n1)))"
            }
            if k1 != k2 { code = "\(type)(\(code))" }
            return code
        case (.vector(let k1, _), .scalar(let k2)):
            let code = "\(parenthesized(v.code)).x"
            return k1 == k2 ? code : "\(k2.name)(\(code))"
        case (.matrix(_, let r1, let c1), .matrix(let k, let r2, let c2)) where r2 <= r1 && c2 <= c1:
            // Top-left block; rows are the stored columns.
            let rows = (0..<r2).map { "\(parenthesized(v.code))[\($0)].\(String("xyzw".prefix(c2)))" }
            return "\(HType.matrix(k, r2, c2))(\(rows.joined(separator: ", ")))"
        case (.scalar, .matrix):
            return "\(type)(\(try convert(v, to: .float)))"
        case (.vector(_, let n), .matrix(_, let r, let c)) where n == r * c:
            // HLSL lists rows; the transposed MSL matrix takes the same list as columns.
            let name = parenthesized(v.code)
            let parts = (0..<n).map { "\(name)[\($0)]" }
            return "\(type)(\(parts.joined(separator: ", ")))"
        case (.array, .array):
            return v.code
        default:
            throw ShaderError.semantic("can't convert \(v.type) to \(type)", 0)
        }
    }
}
