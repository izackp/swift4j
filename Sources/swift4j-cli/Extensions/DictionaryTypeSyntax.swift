import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


// `[Key: Value]` bridges to the runtime `Dictionary` conformance, which marshals
// to `java/util/Map` (see Java/Extensions/Dictionary+JConvertible.swift). Map
// entries are always boxed objects, so key/value are mapped primitivesAsObjects.
extension DictionaryTypeSyntax: MappableTypeSyntax {
  func map(with ctx: inout ProxyGenerator.Context, primitivesAsObjects: Bool) -> String {
    let k = key.map(with: &ctx, primitivesAsObjects: true)
    let v = value.map(with: &ctx, primitivesAsObjects: true)
    switch ctx.settings.language {
      case .java:
        return "java.util.Map<\(k), \(v)>"
      case .kotlin:
        return "Map<\(k), \(v)>"
    }
  }
}
