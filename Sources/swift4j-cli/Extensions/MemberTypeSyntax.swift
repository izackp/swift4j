import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


extension MemberTypeSyntax: MappableTypeSyntax {
  func map(with ctx: inout ProxyGenerator.Context, primitivesAsObjects: Bool) -> String {
    // Only handle simple `Namespace.Type` references — multi-level member
    // chains beyond two segments aren't currently emitted by any @jvm code
    // path and would risk masking real bugs if silently mapped.
    guard let baseId = baseType.as(IdentifierTypeSyntax.self) else {
      return ""
    }
    let namespaceName = baseId.name.text
    let typeName = name.text

    // If the referenced type is registered as a `@jvm` type under this same
    // namespace, emit it fully-qualified. Importing `CaptureAPI.Server.Subject`
    // would collide with a sibling top-level `Subject` in the same package,
    // so emit the dotted path inline instead (`CaptureAPI.Server.Subject`).
    if ctx.settings.registry.hasNamespacedType(name: typeName, under: [namespaceName]) {
      let qualified = "\(ctx.package).\(namespaceName).\(typeName)"
      if let genericArgs = genericArgumentClause?.arguments, !genericArgs.isEmpty {
        let mappedGenericArgs = genericArgs.map { $0.argument.map(with: &ctx, primitivesAsObjects: true) }
        return "\(qualified)<\(mappedGenericArgs.joined(separator: ", "))>"
      }
      return qualified
    }

    // Cross-module nested resolution: the scan pre-pass emits namespaced
    // @jvm types in dotted form (e.g. "Server.Subject"), so a dotted entry
    // in `externalPackages` resolves a reference to a namespaced type that
    // lives in another module. Same collision rationale as above — sibling
    // top-level types with the matching unqualified name shadow the import,
    // so we emit the dotted path inline.
    let dotted = "\(namespaceName).\(typeName)"
    if let pkg = ctx.settings.externalPackages[dotted] {
      let qualified = "\(pkg).\(namespaceName).\(typeName)"
      if let genericArgs = genericArgumentClause?.arguments, !genericArgs.isEmpty {
        let mappedGenericArgs = genericArgs.map { $0.argument.map(with: &ctx, primitivesAsObjects: true) }
        return "\(qualified)<\(mappedGenericArgs.joined(separator: ", "))>"
      }
      return qualified
    }

    // Fallback: try external-package resolution against the bare type name
    // (same behaviour as IdentifierTypeSyntax for unknown identifiers).
    return ctx.settings.externalPackages[typeName].map { _ in
      ctx.imports.insert("\(ctx.settings.externalPackages[typeName]!).\(typeName)")
      return typeName
    } ?? typeName
  }
}
