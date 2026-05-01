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
  }

  private let package: String
  private let settings: Settings

  private var typeGens: [TypeGeneratorProtocol] = []

  init(package: String, javaVersion: Int) {
    self.package = package
    self.settings = Settings(language: .java(version: javaVersion), registry: TypeRegistry())

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
      let sourceFile = Parser.parse(source: source)
      parsedFiles.append(sourceFile)
      RegistryPopulator(registry: settings.registry).walk(sourceFile)
    }

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
                                        settings: .init(language: language, registry: self.settings.registry),
                                        imports: self.imports)
    let res = body(&tmpCtx)
    self.imports = tmpCtx.imports

    return res
  }
}


/// Pre-pass walker: indexes all top-level @jvm types and all extensions.
private final class RegistryPopulator: SyntaxVisitor {
  let registry: TypeRegistry

  init(registry: TypeRegistry) {
    self.registry = registry
    super.init(viewMode: .fixedUp)
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
    }
    return .skipChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
    }
    return .skipChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported {
      registry.register(node)
    }
    return .skipChildren
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    registry.register(node)
    // Do not descend into the extension body during registration. Types
    // nested inside extensions are not top-level and must not be added
    // to the top-level type table (which would shadow real types of the
    // same name and pull in unrelated extensions).
    return .skipChildren
  }
}
