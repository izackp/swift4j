/// A value type whose Java peer wraps a raw pointer to Swift storage, so a peer
/// can be built around an address the peer does not own.
///
/// Conformance is emitted by `@jvm` / `@jvmBinding` for value types. Types that
/// bridge by *conversion* rather than pointer-boxing — `Date` -> `java.util.Date`,
/// `URL`, `Result`, `Dictionary` — deliberately do not conform: there is no
/// address for their peer to hold.
public protocol JvmPointerBoxed: JObjectConvertible {
  /// Builds a peer around `raw` without transferring ownership. The peer must
  /// not outlive the caller's scope.
  static func fromUnownedPointer(_ raw: UnsafeMutableRawPointer) -> JavaObject?
}


/// Hands `value` to a Java `SwiftBorrow` callback for the duration of the call.
///
/// Two overloads, resolved at compile time. The macro emits the same call for
/// every property because it cannot know which applies (it sees the property's
/// type as bare syntax); the type checker picks.
///
/// Pointer-boxed: the callback receives a peer pointing straight at `value`.
/// No copy, and writes through the peer are writes into `value`.
public func _jvmScopedBorrow<T: JvmPointerBoxed>(_ value: inout T, _ body: JavaObject?) {
  guard let body else { return }
  withUnsafeMutablePointer(to: &value) { p in
    guard let peer = T.fromUnownedPointer(UnsafeMutableRawPointer(p)) else { return }
    JObject(body).call(method: "with", sig: "(Ljava/lang/Object;)V", [peer.toJavaParameter()])
  }
}

/// Fallback for types that bridge by conversion. The callback receives a
/// converted object and the result is read back, so writes still land, but it
/// is a copy rather than a view.
///
/// swift4j-cli does not expose a public `unsafeWith*` for these, so nothing
/// generated reaches this. It exists so the emitted thunk compiles for every
/// property type, and behaves correctly rather than trapping if it ever is.
public func _jvmScopedBorrow<T: JObjectConvertible>(_ value: inout T, _ body: JavaObject?) {
  guard let body else { return }
  guard let peer = value.toJavaObject() else { return }
  JObject(body).call(method: "with", sig: "(Ljava/lang/Object;)V", [peer.toJavaParameter()])
  value = T.fromJavaObject(peer)
}
