import Foundation

import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class ProxyGenerator: SyntaxVisitor {
  struct Context {
    let package: String
    let settings: Settings

    var imports: Set<String> = []
  }

  struct Settings {
    enum Language {
      case java(version: Int)
      case kotlin
    }

    let language: Language
    let registry: TypeRegistry
    /// Map of unqualified type names to the Java package they live in,
    /// used to qualify references to @jvm types defined in other Swift
    /// modules (own-module types resolve via the type registry instead).
    let externalPackages: [String: String]

    init(language: Language, registry: TypeRegistry, externalPackages: [String: String] = [:]) {
      self.language = language
      self.registry = registry
      self.externalPackages = externalPackages
    }
  }

  private let package: String
  private let settings: Settings

  private var typeGens: [TypeGeneratorProtocol] = []

  init(package: String, javaVersion: Int, externalPackages: [String: String] = [:]) {
    self.package = package
    self.settings = Settings(language: .java(version: javaVersion), registry: TypeRegistry(), externalPackages: externalPackages)

    super.init(viewMode: .fixedUp)
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && settings.registry.parentDecl(of: node) == nil {
      typeGens.append(ClassGenerator(node, settings: settings))
    }
    return .skipChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && settings.registry.parentDecl(of: node) == nil {
      typeGens.append(ClassGenerator(node, settings: settings))
    }
    return .skipChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && settings.registry.parentDecl(of: node) == nil {
      typeGens.append(EnumGenerator(node, settings: settings))
    }
    return .skipChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    // Recurse into extensions to find nested @jvm types declared inside.
    return .visitChildren
  }

  /// Runs the pre-pass: parse all files, populate registry with top-level
  /// @jvm types and all extensions. Then runs generation pass per file.
  func run(paths: [String]) throws -> [(filename: String, source: String)] {
    var parsedFiles: [SourceFileSyntax] = []

    for path in paths {
      let url = URL(fileURLWithPath: path)
      let source = try String(contentsOf: url, encoding: .utf8)
      let parsed = Parser.parse(source: source)
      // Rewrite @jvmBinding(T.self) stubs into plain `@jvm T` before registry
      // population and generation, so foreign-type bindings flow through the
      // normal codegen path named after the foreign type.
      let sourceFile = JvmBindingRewriter().rewrite(parsed).as(SourceFileSyntax.self) ?? parsed
      parsedFiles.append(sourceFile)
      RegistryPopulator(registry: settings.registry).walk(sourceFile)
    }

    settings.registry.finalizeNamespaces()

    for sourceFile in parsedFiles {
      walk(sourceFile)
    }

    return typeGens.map { generate($0) }
  }

  /// Single-file path retained for backward compatibility (used in tests).
  func run(path: String) throws -> [(filename: String, source: String)] {
    return try run(paths: [path])
  }

  func generate(_ typeGen: TypeGeneratorProtocol) -> (filename: String, source: String) {
    var ctx = Context(package: package, settings: settings)

    let typeProxy = typeGen.generate(with: &ctx)
    return typeProxy.generate(in: package, with: ctx.imports)
  }

  func generatePackageClass() -> String {
"""
package \(self.package);

"""
  }
}


extension ProxyGenerator.Context {
  mutating func with<R>(language: ProxyGenerator.Settings.Language, _ body: (inout ProxyGenerator.Context) -> R) -> R {
    var tmpCtx = ProxyGenerator.Context(package: self.package,
                                        settings: .init(language: language, registry: self.settings.registry, externalPackages: self.settings.externalPackages),
                                        imports: self.imports)
    let res = body(&tmpCtx)
    self.imports = tmpCtx.imports

    return res
  }
}

extension ProxyGenerator {
  /// Scan-only pass used by build plugins to discover the @jvm types
  /// contributed by a module before any code generation runs. Returns the
  /// set of names that would be emitted as Java classes. Namespaced types
  /// (declared inside `extension SomeNamespace { @jvm ... }`) appear in
  /// dotted form (e.g. `Server.Subject`) AND in bare form, so consumers
  /// that resolve cross-module references by either spelling find them.
  ///
  /// Both spellings are emitted because:
  /// - The bare name is needed for `IdentifierTypeSyntax` resolution when
  ///   a caller writes `Subject` and means the top-level @jvm type.
  /// - The dotted name is needed for `MemberTypeSyntax` resolution when a
  ///   caller writes `Server.Subject` and means the namespaced @jvm type
  ///   that lives in the `Server` subpackage. Without the dotted entry,
  ///   the lookup falls back to the bare-`Subject` mapping and resolves
  ///   to the wrong Java class (the sibling top-level Subject).
  static func scanTopLevelJvmTypes(paths: [String]) throws -> Set<String> {
    let registry = TypeRegistry()
    for path in paths {
      let url = URL(fileURLWithPath: path)
      let source = try String(contentsOf: url, encoding: .utf8)
      let parsed = Parser.parse(source: source)
      let sourceFile = JvmBindingRewriter().rewrite(parsed).as(SourceFileSyntax.self) ?? parsed
      ScanPopulator(registry: registry).walk(sourceFile)
    }
    registry.finalizeNamespaces()
    var names: Set<String> = []
    for (name, decl) in registry.topLevelTypes where registry.parentDecl(of: decl) == nil {
      names.insert(name)
      let namespace = registry.namespacePath(for: decl)
      if !namespace.isEmpty {
        names.insert((namespace + [name]).joined(separator: "."))
      }
    }
    return names
  }
}

/// Pre-pass walker used by --scan-types. Tracks namespace context so
/// `extension Foo { @jvm struct Bar }` is reported as `Foo.Bar` in
/// addition to the bare `Bar`. Mirrors RegistryPopulator's behaviour
/// but kept distinct so the internal generation pass can evolve
/// without surprising the scan output.
private final class ScanPopulator: SyntaxVisitor {
  let registry: TypeRegistry

  /// Stack of identifier-only extension extended-types currently being
  /// traversed. Each entry contributes a namespace segment for any
  /// `@jvm` type discovered inside its body.
  private var extensionStack: [String] = []

  init(registry: TypeRegistry) {
    self.registry = registry
    super.init(viewMode: .fixedUp)
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
      if !extensionStack.isEmpty {
        registry.recordCandidateNamespace(for: node, path: extensionStack)
      }
    }
    return .skipChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
      if !extensionStack.isEmpty {
        registry.recordCandidateNamespace(for: node, path: extensionStack)
      }
    }
    return .skipChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
      if !extensionStack.isEmpty {
        registry.recordCandidateNamespace(for: node, path: extensionStack)
      }
    }
    return .skipChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    registry.register(node)
    guard let ident = node.extendedType.as(IdentifierTypeSyntax.self) else {
      return .skipChildren
    }
    extensionStack.append(ident.name.text)
    walk(node.memberBlock)
    extensionStack.removeLast()
    return .skipChildren
  }
}


/// Pre-pass walker: indexes all top-level @jvm types and all extensions.
private final class RegistryPopulator: SyntaxVisitor {
  let registry: TypeRegistry

  /// Stack of identifier-only extension extended-types currently being
  /// traversed. Each entry contributes a namespace segment for any
  /// `@jvm` type discovered inside its body.
  private var extensionStack: [String] = []

  init(registry: TypeRegistry) {
    self.registry = registry
    super.init(viewMode: .fixedUp)
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
      if !extensionStack.isEmpty {
        registry.recordCandidateNamespace(for: node, path: extensionStack)
      }
    }
    return .skipChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
      if !extensionStack.isEmpty {
        registry.recordCandidateNamespace(for: node, path: extensionStack)
      }
    }
    return .skipChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
      if !extensionStack.isEmpty {
        registry.recordCandidateNamespace(for: node, path: extensionStack)
      }
    }
    return .skipChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    registry.register(node)
    // Descend INTO the extension to register @jvm types declared inside as
    // namespaced types (subpackage emission). Only simple-identifier
    // extended types are namespace candidates; member-typed extensions
    // (`extension Foo.Bar { … }`) imply real nesting and are skipped.
    guard let ident = node.extendedType.as(IdentifierTypeSyntax.self) else {
      return .skipChildren
    }
    extensionStack.append(ident.name.text)
    walk(node.memberBlock)
    extensionStack.removeLast()
    return .skipChildren
  }
}
