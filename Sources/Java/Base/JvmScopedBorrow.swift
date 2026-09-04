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


/// The callback method, resolved once.
///
/// `JObject(body).call(method:sig:)` costs four JNI operations before the call
/// it wants: a global ref allocated and freed, a reflective `getClass()`, and a
/// string-keyed `GetMethodID` — every time. Measured, that dominated a scope
/// entry, and `unsafeForEach` paid it per element.
///
/// The target never varies: `SwiftBorrow` has one method. So resolve it once
/// and invoke on the raw local ref, which is valid for the whole native call.
fileprivate let SwiftBorrow__class = JClass(jni.FindClass("io/scade/swift4j/SwiftBorrow")!)
fileprivate let SwiftBorrow__with =
  SwiftBorrow__class.getMethodID(name: "with", sig: "(Ljava/lang/Object;)V")!

@inline(__always)
private func _invoke(_ body: JavaObject, _ peer: JavaObject) {
  jni.CallVoidMethod(body, SwiftBorrow__with, [JavaParameter(object: peer)])
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
    _invoke(body, peer)
  }
}

/// Optional payload, borrowed in place.
///
/// Force-unwrap is an lvalue, so `&value!` addresses the payload where it lies
/// rather than materialising a temporary. Measured on a stored optional: a
/// write through the pointer reaches the original, the address is stable across
/// separate borrows, and it falls inside the owner's own storage. That makes
/// this a real borrow with no copy, the same as the non-optional case — which
/// matters, because avoiding the copy is what the whole scope mechanism is for.
///
/// `nil` runs the body zero times, matching `if let`. The check has to come
/// first: force-unwrapping `nil` traps.
public func _jvmScopedBorrow<T: JvmPointerBoxed>(_ value: inout T?, _ body: JavaObject?) {
  guard let body, value != nil else { return }
  withUnsafeMutablePointer(to: &value!) { p in
    guard let peer = T.fromUnownedPointer(UnsafeMutableRawPointer(p)) else { return }
    _invoke(body, peer)
  }
}

/// Fallback for an optional whose payload bridges by conversion, mirroring the
/// non-optional fallback below. Nothing generated reaches it; it exists so the
/// emitted thunk compiles for every optional property type.
public func _jvmScopedBorrow<T: JObjectConvertible>(_ value: inout T?, _ body: JavaObject?) {
  guard let body, var unwrapped = value else { return }
  guard let peer = unwrapped.toJavaObject() else { return }
  _invoke(body, peer)
  unwrapped = T.fromJavaObject(peer)
  value = unwrapped
}

/// Every element of an array, borrowed in place, one at a time.
///
/// `withUnsafeMutableBufferPointer` yields the storage directly, so element
/// addresses are stable for the duration and writes land in the array rather
/// than in a per-element copy. That is the whole difference from the getter,
/// which boxes an owned copy per element and drops every write.
///
/// It also moves the buffer out of the array for the duration, which makes
/// touching the original array inside the closure undefined. Nothing in Swift
/// catches that here — the array is reached through `UnsafeMutablePointer`,
/// which exclusivity enforcement does not instrument. The peer's `_inScope`
/// seal is what prevents it, so this is only sound alongside that.
public func _jvmScopedBorrowEach<T: JvmPointerBoxed>(_ value: inout [T], _ body: JavaObject?) {
  guard let body else { return }
  value.withUnsafeMutableBufferPointer { buf in
    guard let base = buf.baseAddress else { return }
    for i in 0..<buf.count {
      guard let peer = T.fromUnownedPointer(UnsafeMutableRawPointer(base + i)) else { continue }
      _invoke(body, peer)
    }
  }
}

/// One element of an array, addressed by index.
///
/// The copying getter marshals the whole array to hand back one element, so
/// reaching index 2 of ten thousand costs ten thousand boxes and about 13 ms.
/// This is O(1): one scope, one element, however long the array is.
///
/// An out-of-range index runs the body zero times. The Java wrapper turns that
/// into the IndexOutOfBoundsException a caller expects from an index.
public func _jvmScopedBorrowElement<T: JvmPointerBoxed>(_ value: inout [T], _ index: Int, _ body: JavaObject?) {
  guard let body, value.indices.contains(index) else { return }
  value.withUnsafeMutableBufferPointer { buf in
    guard let base = buf.baseAddress else { return }
    guard let peer = T.fromUnownedPointer(UnsafeMutableRawPointer(base + index)) else { return }
    _invoke(body, peer)
  }
}

/// Fallback mirroring the one below, for a conversion-bridged element.
public func _jvmScopedBorrowElement<T: JObjectConvertible>(_ value: inout [T], _ index: Int, _ body: JavaObject?) {
  guard let body, value.indices.contains(index) else { return }
  guard let peer = value[index].toJavaObject() else { return }
  _invoke(body, peer)
  value[index] = T.fromJavaObject(peer)
}

/// Fallback for an array whose element bridges by conversion. Elements are
/// converted and written back per iteration, so writes still land, but each is
/// a copy. Nothing generated reaches this; it exists so the emitted thunk
/// compiles for every array property type.
public func _jvmScopedBorrowEach<T: JObjectConvertible>(_ value: inout [T], _ body: JavaObject?) {
  guard let body else { return }
  for i in value.indices {
    guard let peer = value[i].toJavaObject() else { continue }
    _invoke(body, peer)
    value[i] = T.fromJavaObject(peer)
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
  _invoke(body, peer)
  value = T.fromJavaObject(peer)
}
