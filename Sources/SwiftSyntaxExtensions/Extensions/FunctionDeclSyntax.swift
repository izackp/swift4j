import SwiftSyntax


extension FunctionDeclSyntax: MemberDeclSyntax {
  public var isAsync: Bool {
    signature.effectSpecifiers?.asyncSpecifier != nil
  }

  public var isThrowing: Bool {
    signature.effectSpecifiers?.throwsClause != nil
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
  public func isBridgeable(typeConformsToHashable: Bool) -> Bool {
    return !(typeConformsToHashable && isEqualityOperator)
  }
}


