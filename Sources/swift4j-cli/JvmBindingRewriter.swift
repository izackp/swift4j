import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


/// Pre-pass for the Java/Kotlin generator: rewrites a foreign-type binding
///
///     @jvmBinding
///     extension SourceInfo: JObjectConvertible {
///         static func makeForJVM(instanceId: Int64, type: String) -> SourceInfo { … }
///         // optional forwarding getters: func jvmX() -> T { … }
///     }
///
/// into a synthetic first-party `@jvm` struct named after the foreign type:
///
///     @jvm
///     public struct SourceInfo {
///         public init(instanceId: Int64, type: String) {}   // from makeForJVM
///         public func jvmX() -> T {}                         // forwarded methods
///     }
///
/// so the existing `ClassGenerator` emits the typed Kotlin/Java peer
/// (`SwiftPtr`-backed class with a constructor → `init0`, `class_init`, `deinit`,
/// `fromPtr`). The native names line up with `JvmBindingMacro`'s thunks on the
/// Swift/JNI side. Mirrors jvm_foreign_binding.md.
final class JvmBindingRewriter: SyntaxRewriter {
  static let factoryName = "makeForJVM"

  override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
    guard hasJvmBinding(node.attributes),
          let foreign = node.extendedType.as(IdentifierTypeSyntax.self)?.name.text else {
      return DeclSyntax(node)
    }

    // The manually-specified factory provides the initializer signature.
    let factory = node.memberBlock.members.lazy
      .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .first { $0.name.text == Self.factoryName && $0.isStatic }
    let initParams = factory?.signature.parameterClause.parameters.trimmedDescription ?? ""

    // Forwarding instance methods (everything except the factory) → bridged methods.
    let methods = node.memberBlock.members
      .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .filter { !($0.name.text == Self.factoryName && $0.isStatic) }
      .map { fn -> String in
        let sig = fn.signature.trimmedDescription
        return "    public func \(fn.name.text)\(sig) {}"
      }
      .joined(separator: "\n")

    let source =
"""
@jvm
public struct \(foreign) {
    public init(\(initParams)) {}
\(methods)
}
"""
    let parsed = Parser.parse(source: source)
    guard let structDecl = parsed.statements.first?.item.as(StructDeclSyntax.self) else {
      return DeclSyntax(node)
    }
    return DeclSyntax(structDecl)
  }

  private func hasJvmBinding(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
      guard case let .attribute(attr) = element else { return false }
      return attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "jvmBinding"
    }
  }
}
