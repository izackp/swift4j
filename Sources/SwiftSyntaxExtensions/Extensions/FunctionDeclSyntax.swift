import SwiftSyntax


extension FunctionDeclSyntax: MemberDeclSyntax {
  public var isAsync: Bool {
    signature.effectSpecifiers?.asyncSpecifier != nil
  }

  public var isThrowing: Bool {
    signature.effectSpecifiers?.throwsClause != nil
  }

  public var isMutating: Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.mutating) }
  }

  /// `==` or `!=`.
  public var isEqualityOperator: Bool {
    name.text == "==" || name.text == "!="
  }

  /// Whether swift4j should emit a JNI bridge for this func, given whether the
  /// enclosing type conforms to `Hashable`. Must be applied identically on the
  /// macro (Swift thunks + native registration) and CLI (Java proxy) sides, or
  /// `RegisterNatives` would mismatch.
  ///
  /// Only `==`/`!=` on a `Hashable` type are skipped — they're superseded by
  /// the synthesized Java `equals` (which already calls Swift `==`) and would
  /// otherwise collide on the `equalsImpl` native name. `hash(into:)` IS
  /// bridged: `Hasher` is bridgeable (see `Hasher` JConvertible adapter) and
  /// rides the general `inout` path.
  /// Members that implement the bridge itself rather than the type's API.
  ///
  /// Normally these are macro-generated and never appear in the source the
  /// generators walk. They do appear when an author hand-writes a conversion —
  /// which `@jvm(serialized:)` requires for a type whose storage is not fully
  /// marshalled. Bridging one produces a Java method taking `JavaObject`, which
  /// has no Java mapping, and registers a native nothing provides.
  private static let bridgeWitnessNames: Set<String> = [
    "fromJavaObject", "toJavaObject", "fromUnownedPointer", "toJavaParameter",
  ]

  public func isBridgeable(typeConformsToHashable: Bool) -> Bool {
    if Self.bridgeWitnessNames.contains(name.text) { return false }
    return !(typeConformsToHashable && isEqualityOperator)
  }
}


