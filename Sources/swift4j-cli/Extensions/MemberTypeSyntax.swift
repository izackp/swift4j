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
    // namespace, emit it as a subpackage-qualified import + bare type name.
    if ctx.settings.registry.hasNamespacedType(name: typeName, under: [namespaceName]) {
      ctx.imports.insert("\(ctx.package).\(namespaceName).\(typeName)")
      // Generics: defer to the generic args of the member name (rare path).
      if let genericArgs = genericArgumentClause?.arguments, !genericArgs.isEmpty {
        let mappedGenericArgs = genericArgs.map { $0.argument.map(with: &ctx, primitivesAsObjects: true) }
        return "\(typeName)<\(mappedGenericArgs.joined(separator: ", "))>"
      }
      return typeName
    }

    // Fallback: try external-package resolution against the bare type name
    // (same behaviour as IdentifierTypeSyntax for unknown identifiers).
    return ctx.settings.externalPackages[typeName].map { _ in
      ctx.imports.insert("\(ctx.settings.externalPackages[typeName]!).\(typeName)")
      return typeName
    } ?? typeName
  }
}
