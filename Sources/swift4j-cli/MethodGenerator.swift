import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class MethodGenerator {
  typealias Context = ProxyGenerator.Context

  private let funcDecl: FunctionDeclSyntax
  private let className: String

  var name: String { funcDecl.name.text }

  init(_ funcDecl: FunctionDeclSyntax, className: String) {
    self.funcDecl = funcDecl
    self.className = className
  }

  func generate(with ctx: inout Context) -> String {
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


    return
"""
  public \(modifiers) \(retType) \(name)(\(paramDecls.joined(separator: ", "))) \(throwsClause) {    
    \(call);    
  }
  private \(modifiers) native \(retType) \(name)Impl(\(paramDeclsImpl.joined(separator: ", "))) \(throwsClause);
"""
  }
}
