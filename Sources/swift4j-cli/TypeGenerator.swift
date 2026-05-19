import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


protocol TypeGeneratorProtocol {
  var name: String { get }

  var isRefType: Bool { get }

  func generate(with ctx: inout ProxyGenerator.Context) -> TypeProxy
}


extension TypeGeneratorProtocol {
  var isRefType: Bool { return true }
}


class TypeGenerator<T: TypeDeclSyntax>: SyntaxVisitor {
  typealias Context = ProxyGenerator.Context

  let typeDecl: T
  let settings: ProxyGenerator.Settings

  var nestedTypeGens: [any TypeGeneratorProtocol] = []

  var name: String { typeDecl.typeName }

  /// True if this type is nested inside another @jvm type, considering
  /// both syntactic nesting and extension-defined nesting.
  var nested: Bool { settings.registry.parentDecl(of: typeDecl) != nil }

  /// Namespace path for types declared inside a Swift namespace extension
  /// (e.g. `extension Server { @jvm struct Subject }` → `["Server"]`).
  /// Empty for top-level / type-nested declarations. Used to emit the type
  /// into a Java subpackage so multiple Swift `Subject` declarations (one
  /// in `extension Server`, one top-level) can coexist without colliding
  /// at the JNI class-registration layer.
  var namespacePath: [String] {
    return settings.registry.namespacePath(forType: typeDecl.typeName)
  }

  /// Walks the parent chain via the registry (extension-aware).
  var registryParents: [any TypeDeclSyntax] {
    return settings.registry.parents(of: typeDecl)
  }

  init(_ typeDecl: T, settings: ProxyGenerator.Settings) {
    self.typeDecl = typeDecl
    self.settings = settings

    super.init(viewMode: .fixedUp)

    walk(typeDecl)

    // Also walk all extensions of this type to discover nested types
    // declared in extensions (cross-file or same-file).
    let parents = settings.registry.parents(of: typeDecl)
    for ext in settings.registry.extensions(of: typeDecl, parents: parents) {
      walk(ext)
    }
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.hashValue != typeDecl.hashValue && node.isExported {
      nestedTypeGens.append(ClassGenerator(node, settings: settings))
      return .skipChildren
    }
    return .visitChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.hashValue != typeDecl.hashValue && node.isExported {
      nestedTypeGens.append(ClassGenerator(node, settings: settings))
      return .skipChildren
    }
    return .visitChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.hashValue != typeDecl.hashValue && node.isExported {
      nestedTypeGens.append(EnumGenerator(node, settings: settings))
      return .skipChildren
    }
    return .visitChildren
  }
}
