import SwiftSyntax
import SwiftSyntaxExtensions


/// Indexes top-level @jvm types and extensions across all input files.
///
/// Required because Swift parses one file at a time. Cross-file extensions
/// (and even same-file extensions) are not connected to their extended type
/// in the syntax tree, so a registry pre-pass is needed to resolve nesting.
final class TypeRegistry {
  /// Unqualified type name -> the top-level @jvm type declaration.
  /// Limitation: assumes top-level type names are unique across input files.
  private(set) var topLevelTypes: [String: any TypeDeclSyntax] = [:]

  /// Namespace path for each registered top-level @jvm type. Populated for
  /// types declared inside `extension Foo { ... }` where `Foo` itself is
  /// NOT a registered @jvm type — those extensions are treated as Swift
  /// namespaces and produce a Java subpackage on emission.
  ///
  /// Lookups by unqualified type name return an empty array for non-
  /// namespaced types. Cleared and rebuilt after registration completes via
  /// `finalizeNamespaces()`, so any type whose namespace is itself a real
  /// @jvm type gets reclassified as a regular nested type (handled by the
  /// existing parents/inner-class machinery instead of the subpackage path).
  private(set) var namespaceForType: [String: [String]] = [:]

  /// All extension blocks with their extended-type expressions captured as
  /// a list of identifiers (e.g. `extension Foo.Bar` -> ["Foo", "Bar"]).
  private(set) var allExtensions: [(path: [String], decl: ExtensionDeclSyntax)] = []

  func register(_ decl: any TypeDeclSyntax) {
    topLevelTypes[decl.typeName] = decl
  }

  /// Record a `@jvm` type's syntactic namespace path. Called by the
  /// registry populator when the declaration lives inside an extension of
  /// a simple-identifier extended type. Final namespace mapping is decided
  /// in `finalizeNamespaces()` once all top-level types are known.
  func recordCandidateNamespace(forType typeName: String, path: [String]) {
    namespaceForType[typeName] = path
  }

  /// Strip namespace records whose root identifier IS itself a registered
  /// `@jvm` top-level type — those are real type-nested declarations, not
  /// namespaced ones, and must flow through the existing parents chain.
  func finalizeNamespaces() {
    namespaceForType = namespaceForType.filter { _, path in
      guard let first = path.first else { return false }
      return topLevelTypes[first] == nil
    }
  }

  /// Namespace path for the given unqualified type name, or `[]` if it is
  /// not namespaced.
  func namespacePath(forType typeName: String) -> [String] {
    return namespaceForType[typeName] ?? []
  }

  func register(_ ext: ExtensionDeclSyntax) {
    let path = Self.extendedTypePath(ext)
    guard !path.isEmpty else { return }
    allExtensions.append((path: path, decl: ext))
  }

  /// Returns extensions whose extended-type matches the given type considering
  /// its parent context. A nested type only matches qualified extensions
  /// (e.g. `extension Outer.Inner`); a top-level type matches unqualified
  /// extensions of the same name.
  func extensions(of typeDecl: any TypeDeclSyntax, parents: [any TypeDeclSyntax]) -> [ExtensionDeclSyntax] {
    let qualifiedPath = parents.map { $0.typeName } + [typeDecl.typeName]
    let isNested = !parents.isEmpty
    return allExtensions.compactMap { entry in
      if entry.path == qualifiedPath {
        return entry.decl
      }
      if !isNested && entry.path.count == 1 && entry.path[0] == typeDecl.typeName {
        return entry.decl
      }
      return nil
    }
  }

  func topLevelType(named name: String) -> (any TypeDeclSyntax)? {
    return topLevelTypes[name]
  }

  /// Walks up from a decl looking for a TypeDeclSyntax parent. Treats an
  /// ExtensionDeclSyntax in the chain as a parent reference and resolves
  /// it via the registry. Multi-segment extension paths (e.g.
  /// `extension Outer.Inner`) walk into nested types as needed.
  func parentDecl(of decl: any DeclSyntaxProtocol) -> (any TypeDeclSyntax)? {
    var current: Syntax? = Syntax(decl).parent
    while let node = current {
      if let proto = node.asProtocol(SyntaxProtocol.self) as? DeclSyntaxProtocol,
         let typeDecl = proto as? any TypeDeclSyntax {
        return typeDecl
      }
      if let ext = node.as(ExtensionDeclSyntax.self) {
        let path = Self.extendedTypePath(ext)
        return resolvePath(path)
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

  /// Resolves a dotted path of identifiers (e.g. ["Outer", "Inner"]) by
  /// walking through registered top-level types and their nested @jvm types.
  func resolvePath(_ path: [String]) -> (any TypeDeclSyntax)? {
    guard let first = path.first, var current = topLevelTypes[first] else { return nil }
    for component in path.dropFirst() {
      var found: (any TypeDeclSyntax)? = nil
      for member in current.memberBlock.members {
        if let cls = member.decl.as(ClassDeclSyntax.self), cls.typeName == component, cls.isExported {
          found = cls
          break
        }
        if let s = member.decl.as(StructDeclSyntax.self), s.typeName == component, s.isExported {
          found = s
          break
        }
        if let e = member.decl.as(EnumDeclSyntax.self), e.typeName == component, e.isExported {
          found = e
          break
        }
      }
      guard let next = found else { return nil }
      current = next
    }
    return current
  }

  static func extendedTypePath(_ ext: ExtensionDeclSyntax) -> [String] {
    return identifierPath(of: ext.extendedType)
  }

  private static func identifierPath(of type: TypeSyntax) -> [String] {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return [identifier.name.text]
    }
    if let member = type.as(MemberTypeSyntax.self) {
      return identifierPath(of: TypeSyntax(member.baseType)) + [member.name.text]
    }
    return []
  }
}
