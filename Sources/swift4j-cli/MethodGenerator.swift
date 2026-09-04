import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class MethodGenerator {
  typealias Context = ProxyGenerator.Context

  private let funcDecl: FunctionDeclSyntax
  private let className: String

  var name: String { funcDecl.name.text }

  /// A closure parameter means Java code runs inside the native call, where it
  /// can take JVM monitors and deadlock against a thread waiting on this
  /// peer's. Those methods stay unguarded; see `PeerLock`.
  private var takesClosure: Bool {
    funcDecl.signature.parameterClause.parameters.contains { param in
      var type = param.type
      if let attributed = type.as(AttributedTypeSyntax.self) { type = attributed.baseType }
      if let optional = type.as(OptionalTypeSyntax.self) { type = optional.wrappedType }
      if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
         let only = tuple.elements.first {
        type = only.type
      }
      return type.is(FunctionTypeSyntax.self)
    }
  }

  init(_ funcDecl: FunctionDeclSyntax, className: String) {
    self.funcDecl = funcDecl
    self.className = className
  }

  /// Forwarding declaration for the nested `Borrowed` view, which holds a
  /// checked reference rather than a pointer of its own. Static and async
  /// members are skipped: neither is reached through a borrow.
  func generateForwarding(with ctx: inout Context) -> String? {
    guard !funcDecl.isStatic, !funcDecl.isAsync else { return nil }

    let params = funcDecl.signature.paramsMapping(with: &ctx)
    let retType = funcDecl.signature.returnClause?.type.map(with: &ctx) ?? "void"
    let paramDecls = params.map { "\($0.type) \($0.name)" }
    let args = params.map { $0.name }.joined(separator: ", ")
    let ret = funcDecl.signature.returnClause != nil ? "return " : ""
    let throwsClause = funcDecl.isThrowing ? " throws Exception" : ""

    return
"""
    public \(retType) \(name)(\(paramDecls.joined(separator: ", ")))\(throwsClause) {
      \(ret)view().\(name)(\(args));
    }
"""
  }

  func generate(with ctx: inout Context, sealed: Bool = false, projectable: Bool = false) -> String {
    let params = funcDecl.signature.paramsMapping(with: &ctx)

    // Async funcs return CompletableFuture<T>. Java generics cannot use
    // primitive types, so when the Swift return is a primitive (Int, Bool,
    // …) the inner T must be the boxed reference type. Force
    // primitivesAsObjects=true for that specific case.
    var retType: String
    if funcDecl.isAsync {
      let inner = funcDecl.signature.returnClause?.type.map(with: &ctx, primitivesAsObjects: true) ?? "Void"
      retType = "CompletableFuture<\(inner)>"
      ctx.imports.insert("java.util.concurrent.CompletableFuture")
    } else {
      retType = funcDecl.signature.returnClause?.type.map(with: &ctx) ?? "void"
    }

    let callParams = (funcDecl.isStatic ? [] : ["_ptr()"]) + params.map{$0.name}

    var call = (funcDecl.isStatic ? className : "this") +  ".\(name)Impl(\(callParams.joined(separator: ", ")))"
    call = funcDecl.isAsync || funcDecl.signature.returnClause != nil ? "return \(call)" : call

    let paramDecls = params.map {"\($0.type) \($0.name)"}
    let paramDeclsImpl = (funcDecl.isStatic ? [] : ["long ptr"]) + paramDecls

    let modifiers = funcDecl.isStatic ? "static" : ""

    let throwsClause = funcDecl.isThrowing ? " throws Exception" : ""


    let guarded = PeerLock.guarded("\(call);",
                                   locked: !funcDecl.isStatic && !takesClosure,
                                   sealed: sealed,
                                   owner: "\(className).\(name)")

    // A mutating method on a projection has to reach the owner too, or
    // `box.getLeaf().bump()` would still write into something discarded.
    let args = params.map { $0.name }.joined(separator: ", ")
    let projected: String
    if projectable && !funcDecl.isStatic {
      let body = funcDecl.signature.returnClause != nil || funcDecl.isAsync
        ? "      return _through(v -> v.\(name)(\(args)));\n"
        : "      _through(v -> { v.\(name)(\(args)); return null; });\n      return;\n"
      projected = "    if (_projected()) {\n\(body)    }\n"
    } else {
      projected = ""
    }

    return
"""
  public \(modifiers) \(retType) \(name)(\(paramDecls.joined(separator: ", "))) \(throwsClause) {
\(projected)\(guarded)
  }
  private \(modifiers) native \(retType) \(name)Impl(\(paramDeclsImpl.joined(separator: ", "))) \(throwsClause);
"""
  }
}
