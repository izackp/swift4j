import Foundation

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

  /// True while walking one of this type's extensions rather than its body.
  ///
  /// A member found here is invisible to the `@jvm` macro, which is attached to
  /// the declaration and can only read what is inside its braces. Anything that
  /// depends on the two generators agreeing — a native, a constructor
  /// parameter — therefore cannot work for such a member, so the emitters skip
  /// it. Nested `@jvm` types are unaffected: each carries its own macro.
  private(set) var isWalkingExtension = false

  /// Members dropped for that reason, reported once the walk finishes.
  private(set) var skippedExtensionMembers: [String] = []

  func noteSkippedExtensionMember(_ description: String) {
    skippedExtensionMembers.append(description)

    // Said out loud, because the alternative is silence: before this the member
    // reached Java and failed only when something called it, which for the
    // cases found in CaptureAPI was never.
    let message = """
      swift4j: \(typeDecl.typeName).\(description) is declared in an extension \
      and is not bridged. The @jvm macro is attached to the declaration and \
      cannot see extensions, so nothing would register it. Move it into the \
      type's body to bridge it; ignore this if it is Swift-only.

      """
    FileHandle.standardError.write(Data(message.utf8))
  }

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
    return settings.registry.namespacePath(for: typeDecl)
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
    isWalkingExtension = true
    for ext in settings.registry.extensions(of: typeDecl, parents: parents) {
      walk(ext)
    }
    isWalkingExtension = false
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
