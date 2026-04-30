import SwiftSyntax
import SwiftSyntaxExtensions


/// Indexes top-level @jvm types and extensions across all input files.
///
/// Required because Swift parses one file at a time. Cross-file extensions
/// (and even same-file extensions) are not connected to their extended type
/// in the syntax tree, so a registry pre-pass is needed to resolve nesting.
final class TypeRegistry {
  /// Unqualified type name -> the top-level @jvm type declaration.
  /// Limitation: assumes type names are unique across input files.
  private(set) var topLevelTypes: [String: any TypeDeclSyntax] = [:]

  /// Unqualified extended type name -> list of extension blocks.
  private(set) var extensionsByTypeName: [String: [ExtensionDeclSyntax]] = [:]

  func register(_ decl: any TypeDeclSyntax) {
    topLevelTypes[decl.typeName] = decl
  }

  func register(_ ext: ExtensionDeclSyntax) {
    guard let name = Self.extendedTypeName(ext) else { return }
    extensionsByTypeName[name, default: []].append(ext)
  }

  func extensions(ofType name: String) -> [ExtensionDeclSyntax] {
    return extensionsByTypeName[name] ?? []
  }

  func topLevelType(named name: String) -> (any TypeDeclSyntax)? {
    return topLevelTypes[name]
  }

  /// Walks up from a decl looking for a TypeDeclSyntax parent. Treats an
  /// ExtensionDeclSyntax in the chain as a parent reference and resolves
  /// it via the registry.
  func parentDecl(of decl: any DeclSyntaxProtocol) -> (any TypeDeclSyntax)? {
    var current: Syntax? = Syntax(decl).parent
    while let node = current {
      if let proto = node.asProtocol(SyntaxProtocol.self) as? DeclSyntaxProtocol,
         let typeDecl = proto as? any TypeDeclSyntax {
        return typeDecl
      }
      if let ext = node.as(ExtensionDeclSyntax.self),
         let name = Self.extendedTypeName(ext) {
        return topLevelTypes[name]
      }
      current = node.parent
    }
    return nil
  }

  /// Walks the parent chain to the root, using extension-aware lookup.
  func parents(of decl: any TypeDeclSyntax) -> [any TypeDeclSyntax] {
    var result: [any TypeDeclSyntax] = []
    var current: any TypeDeclSyntax = decl
    while let parent = parentDecl(of: current) {
      result.append(parent)
      current = parent
    }
    return result.reversed()
  }

  static func extendedTypeName(_ ext: ExtensionDeclSyntax) -> String? {
    // Handles `extension Foo` and qualified `extension Outer.Inner`
    // (returns the innermost component).
    return lastIdentifier(of: ext.extendedType)
  }

  private static func lastIdentifier(of type: TypeSyntax) -> String? {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifier.name.text
    }
    if let member = type.as(MemberTypeSyntax.self) {
      return member.name.text
    }
    return nil
  }
}
