import Foundation

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


public struct JvmMacro {
  static func typeDecl(from decl: some DeclSyntaxProtocol) throws -> any JvmTypeDeclSyntax {
    if let classDecl = decl.as(ClassDeclSyntax.self) {
      return classDecl

    } else if let structDecl = decl.as(StructDeclSyntax.self) {
      return structDecl

    } else if let enumDecl = decl.as(EnumDeclSyntax.self) {
      return enumDecl

    } else {
      throw JvmMacrosError.message("@jvm macro can only be applied to a class, struct or enum declaration")
    }
  }

  static func assert(context: some MacroExpansionContext) throws {
    if let enclosingDeclType = context.enclosingDeclType {
      if !enclosingDeclType.isExported {
        throw JvmMacrosError.message(
          "Enclosing type '\(enclosingDeclType.typeName)' is not exported. Add the @jvm attribute to the parent."
        )
      }
    }
  }

  static func addPlatformConditions(_ node: SwiftSyntax.AttributeSyntax, syntax: String) -> String {
    switch node.arguments {
    case .argumentList(let exprs):
      let conds = exprs.compactMap {
          guard let platform = $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text else {
            return nil
          }
          return "os(\(platform))"
        }.joined(separator: " || ")
      
      if conds != "" {
        return
"""
#if \(conds)
\(syntax)
#endif
"""
      }
      return syntax

    default:
      return syntax
    }
  }
}


// MARK: - + MemberMacro

extension JvmMacro: MemberMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingMembersOf declaration: some DeclGroupSyntax,
                               conformingTo protocols: [TypeSyntax],
                               in context: some MacroExpansionContext) throws -> [DeclSyntax] {

    try assert(context: context)

    return try typeDecl(from: declaration).expandMembers(in: context)
  }
}


// MARK: - + MemberAttributeMacro

extension JvmMacro: MemberAttributeMacro {
  public static func expansion(of node: SwiftSyntax.AttributeSyntax,
                               attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
                               providingAttributesFor member: some SwiftSyntax.DeclSyntaxProtocol,
                               in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.AttributeSyntax] {

    if let decl = member.as(VariableDeclSyntax.self), decl.isExported {
      return [AttributeSyntax(stringLiteral: "@jvm_exported")]
    }

    return []
  }
}


// MARK: - + PeerMacro

extension JvmMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingPeersOf declaration: some DeclSyntaxProtocol,
                               in context: some MacroExpansionContext) throws -> [DeclSyntax] {

    // Skip peer emission only when nested inside a real outer type (which
    // handles JNI registration itself). Types nested via extension namespace
    // (e.g. `extension Server { @jvm struct Subject }`) still need their own
    // register-natives peer so the JNI symbol matches the Java subpackage
    // (`Java_CaptureAPI_Server_Subject_Subject_1class_1init`). `expandPeer`
    // adapts the emission for ext-nested via `@_silgen_name` + `static`.
    guard context.enclosingDeclType == nil else {
      return []
    }

    return try typeDecl(from: declaration).expandPeer(in: context)
  }
}


// MARK: - + ExtensionMacro

extension JvmMacro: ExtensionMacro {
  public static func expansion(of node: SwiftSyntax.AttributeSyntax,
                               attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
                               providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol,
                               conformingTo protocols: [SwiftSyntax.TypeSyntax],
                               in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.ExtensionDeclSyntax] {

    try assert(context: context)

    // Value types additionally carry JvmPointerBoxed, which is what lets a
    // scoped borrow hand Java a peer around an address it does not own. A
    // class's peer already refers to the object itself, and taking the address
    // of a class-typed property would yield the address of the reference.
    let isValueType = declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self)
    let conformances = isValueType ? "JObjectConvertible, JvmPointerBoxed" : "JObjectConvertible"

    let extSyntax =
"""
extension \(type.trimmed): \(conformances) { }
"""
    return [try ExtensionDeclSyntax(SyntaxNodeString(stringLiteral: extSyntax))]
  }

}
