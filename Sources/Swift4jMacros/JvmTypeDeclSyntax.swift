import SwiftSyntax
import SwiftSyntaxMacros

import SwiftSyntaxExtensions


protocol JvmTypeDeclSyntax: TypeDeclSyntax {
  var selfExpr: String { get }

  func expandMembers(in context: some MacroExpansionContext) throws -> [DeclSyntax]

  func expandJavaClassDecl(in context: some MacroExpansionContext) -> String

  func expandJavaObjectDecls(in context: some MacroExpansionContext) throws -> String

  func expandCtorDecls(in context: some MacroExpansionContext) throws -> String

  func expandInitCall(params: String, throwing: Bool, failable: Bool, initName: String) throws -> String

  func expandRegisterNatives(in context: some MacroExpansionContext, parents: [any TypeDeclSyntax], namespacePath: [String]) throws -> String

  func expandCreateNativeMethods(parents: [any TypeDeclSyntax], namespacePath: [String]) throws -> [String]
}

extension JvmTypeDeclSyntax {
  var selfExpr: String { "_self(ptr)" }

  func expandMembers(in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    return try expandMembersDefault(in: context)
  }

  func expandJavaClassDecl(in context: some MacroExpansionContext) -> String {
    return try expandJavaClassDeclDefault(in: context)
  }

  func expandRegisterNatives(in context: some MacroExpansionContext, parents: [any TypeDeclSyntax], namespacePath: [String]) throws -> String {
    return try expandRegisterNativesDefault(in: context, parents: parents, namespacePath: namespacePath)
  }

  func expandCreateNativeMethods(parents: [any TypeDeclSyntax], namespacePath: [String]) throws -> [String] {
    return try expandCreateNativeMethodsDefault(parents: parents, namespacePath: namespacePath)
  }
}

extension JvmTypeDeclSyntax {
  // Expand JVM class init function
  func expandPeer(in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    let namespacePath = context.namespaceParentNames
    let jniTypeName = typeName.replacingOccurrences(of: "_", with: "_1")

    // Namespaced @jvm types (`extension Server { @jvm struct Subject }`) emit
    // into a Java subpackage (`CaptureAPI.Server.Subject`), so the JNI cdecl
    // package portion includes the namespace segments. Inner classes via real
    // type nesting still use `$` but are handled by the `parents` chain elsewhere.
    var fqnEscaped = jniTypeName
    let pkgSegments: [String]
    if let moduleName = moduleName(from: context) {
      pkgSegments = [moduleName] + namespacePath
    } else {
      pkgSegments = namespacePath
    }
    if !pkgSegments.isEmpty {
      let escaped = pkgSegments.map { $0.replacingOccurrences(of: "_", with: "_1") }
      fqnEscaped = (escaped + [jniTypeName]).joined(separator: "_")
    }

    // Keep the Swift function name as a simple `<TypeName>_class_init` so it
    // matches the `suffixed(_class_init)` clause on `@jvm`'s @attached(peer).
    // The full namespaced JNI symbol is set separately via @_cdecl/@_silgen_name.
    let cdeclFuncName = "\(typeName)_class_init"

    // Top-level @jvm types emit a true global function with @_cdecl.
    // Extension-namespaced @jvm types (e.g. `extension Server { @jvm struct
    // Subject }`) get their peer expanded INSIDE the extension brace, where
    // @_cdecl is rejected ("can only be applied to global functions").
    // Use @_silgen_name on a `static` func instead: same linkage-name effect,
    // legal inside an extension, and `static` keeps the function free of an
    // implicit `self` so the JNI calling convention still matches.
    let exportSymbol = "Java_\(fqnEscaped)_\(jniTypeName)_1class_1init"
    let isExtensionNested = !namespacePath.isEmpty
    let exportAttr: String
    let funcDecl: String
    if isExtensionNested {
      exportAttr = "@_silgen_name(\"\(exportSymbol)\")"
      funcDecl = "static public func"
    } else {
      exportAttr = "@_cdecl(\"\(exportSymbol)\")"
      funcDecl = "public func"
    }
    let decl =
"""
\( (isMainActorIsolated ?? false) ? "@MainActor" : "")
\(exportAttr)
\(funcDecl) \(cdeclFuncName)(_ env: UnsafeMutablePointer<JNIEnv>, _ cls: JavaClass?) {
  \(try expandRegisterNatives(in: context, parents: [], namespacePath: namespacePath))
}
"""
    return ["\(raw: decl)"]
  }
  
  // Expand members
  func expandMembersDefault(in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    let syntax =
"""
\(expandJavaClassDecl(in: context))
\(try expandJavaObjectDecls(in: context))
\(try expandCtorDecls(in: context))
\(expandFuncDecls(in: context))
\(expandHashableDecls(in: context))
"""

//\(expandVarDecls(in: context))

    return ["\(raw: syntax)"]
  }

  /// Synthesizes JNI thunks for `Object.equals`/`hashCode` when the type
  /// conforms to `Hashable` on its main decl. Delegates to Swift's own
  /// `==` / `hashValue` (which may be `@nonjvm`; we call them as ordinary
  /// Swift members, not as bridged methods). `Int.hashValue` is truncated
  /// into the 32-bit `jint` that Java's `hashCode()` contract requires.
  func expandHashableDecls(in context: some MacroExpansionContext) -> String {
    guard conformsToHashable else { return "" }
    let selfExpr = self.selfExpr
    let otherExpr = selfExpr.replacingOccurrences(of: "ptr", with: "otherPtr")
    return
"""
fileprivate typealias hashCode_jni_t = @convention(c)(UnsafeMutablePointer<JNIEnv>, JavaObject?, JavaLong) -> JavaInt
fileprivate static let hashCode_jni: hashCode_jni_t = { _, _, ptr in
  return JavaInt(truncatingIfNeeded: \(selfExpr).hashValue)
}
fileprivate typealias equals_jni_t = @convention(c)(UnsafeMutablePointer<JNIEnv>, JavaObject?, JavaLong, JavaLong) -> JavaBoolean
fileprivate static let equals_jni: equals_jni_t = { _, _, ptr, otherPtr in
  return JavaBoolean((\(selfExpr) == \(otherExpr)) ? 1 : 0)
}
"""
  }
}


extension JvmTypeDeclSyntax {
  func fqn(with parents: [any TypeDeclSyntax], namespacePath: [String] = []) -> String {
    let chain = namespacePath + parents.map { $0.typeName } + [typeName]
    return chain.joined(separator: ".")
  }

  func fqn(from context: some MacroExpansionContext) -> String {
    let namespacePath = context.namespaceParentNames
    // JNI binary name: package separated by `/`. Namespaced @jvm types live
    // in a subpackage (`CaptureAPI/Server/Subject`), so namespaces join with
    // `/` too. Real inner classes (via TypeDecl nesting) use `$` and are
    // handled at the per-call-site fqn builders, not here.
    var segments: [String] = []
    if let moduleName = moduleName(from: context) {
      segments.append(moduleName)
    }
    segments.append(contentsOf: namespacePath)
    segments.append(typeName)
    return segments.joined(separator: "/")
  }

  func moduleName(from context: some MacroExpansionContext) -> String? {
    guard let segments = context.location(of: self)?.file.as(StringLiteralExprSyntax.self)?.segments,
          segments.count == 1, case .stringSegment(let literalSegment)? = segments.first,
          let moduleNameSep = literalSegment.content.text.firstIndex(of: "/") else { return nil }

    return String(literalSegment.content.text[literalSegment.content.text.startIndex ..< moduleNameSep])
  }
}



extension JvmTypeDeclSyntax {
  func expandJavaClassDeclDefault(in context: some MacroExpansionContext) -> String {
    let fqn = fqn(from: context)
    return
"""
private enum __JClass__ {
  static let name = "\(fqn)"
  static let shared = {
    guard let cls = JClass(fqn: javaName) else {
      fatalError("Could not find \\(javaName) class")
    }
    return cls
  } ()
}

public nonisolated static var javaName: String { __JClass__.name }
public nonisolated static var javaClass: JClass { __JClass__.shared }
"""
  }

  func expandVarDecls(in context: some MacroExpansionContext) -> String {
    return exportedDecls.varDecls
      .compactMap { decl in
        return context.executeAndWarnIfFails(at: decl) {
          return try decl.makeBridgingDecls(typeDecl: self)
        }
      }
      .joined(separator: "\n")
  }

  func expandFuncDecls(in context: some MacroExpansionContext) -> String {
    return exportedDecls.funcDecls
      .filter { $0.isBridgeable(typeConformsToHashable: conformsToHashable) }
      .enumerated()
      .compactMap { i, decl in
        return context.executeAndWarnIfFails(at: decl) {
          return try decl.makeBridgingDecls(typeDecl: self, num: i)
        }
      }
      .joined(separator: "\n")
  }
}


extension JvmTypeDeclSyntax {
  func expandCreateNativeMethodsDefault(parents: [any TypeDeclSyntax], namespacePath: [String] = []) throws -> [String] {
    // Swift-side dispatch target: `(namespace+)?(parents+)?self.<member>`.
    // Namespace segments aren't real Swift types; the call target is the
    // Swift declaration itself, so we drop namespace from this chain and
    // qualify only via real `parents`.
    let fqn = fqn(with: parents)
    let exportedDecls = exportedDecls

    let varNatives: [String] = exportedDecls.varDecls.flatMap { decl in
      guard let bridgings = try? decl.bridgings(typeDecl: self) else { return [String]() }
      return bridgings.map { expandCreateNativeMethod(name: $0.javaName, sig: $0.sig, fn: "\(fqn).\($0.bridgeName)") }
    }

    let funcNatives: [String] = exportedDecls.funcDecls
      .filter { $0.isBridgeable(typeConformsToHashable: conformsToHashable) }
      .enumerated().compactMap {
        guard let jniSig = try? $1.jniSignature() else { return nil }
        let bridge = $1.bridgeName
        return expandCreateNativeMethod(name: "\(bridge)Impl", sig: jniSig, fn: "\(fqn).\(bridge)_\($0)_jni")
      }

    let initNatives: [String] = exportedDecls.initDecls.enumerated().compactMap {
      guard let jniSig = try? $1.jniSignature() else { return nil }
      return expandCreateNativeMethod(name: "init\($0)", sig: jniSig, fn: "\(fqn).init\($0)_jni")
    }

    let deinitNatives = [ expandCreateNativeMethod(name: "deinit", sig: "(J)V", fn: "\(fqn).deinit_jni")]

    // Synthesized Hashable bridge (see `expandHashableDecls`). Names match the
    // private natives the Java `equals`/`hashCode` overrides bind to.
    let hashableNatives: [String] = conformsToHashable ? [
      expandCreateNativeMethod(name: "equalsImpl", sig: "(JJ)Z", fn: "\(fqn).equals_jni"),
      expandCreateNativeMethod(name: "hashCodeImpl", sig: "(J)I", fn: "\(fqn).hashCode_jni"),
    ] : []

    return initNatives + deinitNatives + varNatives + funcNatives + hashableNatives
  }

  func expandRegisterNativesDefault(in context: some MacroExpansionContext, parents: [any TypeDeclSyntax] = [], namespacePath: [String] = []) throws -> String {
    let natives = try expandCreateNativeMethods(parents: parents, namespacePath: namespacePath)

    // Local variable suffix needs to be unique per type within the
    // expandRegisterNatives scope; use the namespace + parent chain so
    // namespaced + nested types don't collide on `\(typeName)_cls`.
    let chainForVar = (namespacePath + parents.map { $0.typeName } + [typeName])
      .joined(separator: "_")

    let cls_expr: String
    if parents.isEmpty && namespacePath.isEmpty {
      cls_expr = "cls"
    } else {
      // JNI FindClass binary name. Package segments (module + namespace
      // extensions) join with `/`; real `parents` (genuine type-nested @jvm
      // declarations) join with `$` for inner-class lookup.
      var pkgSegments: [String] = []
      if let moduleName = moduleName(from: context) {
        pkgSegments.append(moduleName)
      }
      pkgSegments.append(contentsOf: namespacePath)
      let pkgPart = pkgSegments.joined(separator: "/")

      let innerClassChain = (parents.map { $0.typeName } + [typeName])
        .joined(separator: "$")

      let jfqn = pkgPart.isEmpty ? innerClassChain : "\(pkgPart)/\(innerClassChain)"
      cls_expr = "jni.FindClass(\"\(jfqn)\")"
    }

    let registerNatives =
"""
  guard let \(chainForVar)_cls = \(cls_expr) else { return }
  let \(chainForVar)_natives = [
    \(natives.joined(separator: ",\n"))
  ]
  let _ = jni.RegisterNatives(\(chainForVar)_cls, \(chainForVar)_natives)

  \(try exportedDecls.typeDecls
    .compactMap { $0 as? (any JvmTypeDeclSyntax) }
    .map { try $0.expandRegisterNatives(in: context, parents: parents + [self], namespacePath: namespacePath) }
    .joined(separator: "\n")
  )
"""
    return exportAttributes.replaceAll(by: registerNatives)
  }

  func expandCreateNativeMethod(name: String, sig: String, fn: String) -> String {
    return
"""
JNINativeMethod2(name: "\(name)", sig: "\(sig)", fn: unsafeBitCast(\(fn), to: UnsafeMutableRawPointer.self))
"""
  }
}



fileprivate extension AttributeListSyntax {
  func replaceAll(by syntax: String) -> String {
    return self.map { $0.replace(by: syntax) }.joined(separator: "\n")
  }
}

fileprivate extension AttributeListSyntax.Element {
  func replace(by syntax: String) -> String {
    switch self {
    case .attribute(_):
      return syntax
    case .ifConfigDecl(let decl):
      let clauses = decl.clauses.map {
"""
\($0.poundKeyword.text) \($0.condition?.trimmedDescription ?? "")
\($0.elements?.as(AttributeListSyntax.self)?.replaceAll(by: syntax) ?? "" )
"""
      }
      return
"""
\(clauses.joined(separator: "\n"))
#endif 
"""
    }
  }
}
