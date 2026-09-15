/// A Swift value that can write itself into an *existing* Java object instead
/// of constructing a new one.
///
/// This is what keeps a reference held on the Java side from going stale. A
/// `mutating` method bridged onto a serialized peer rebuilds its receiver from
/// that peer's fields, runs the mutation, then has to publish the result. The
/// obvious way — marshal each property and assign it — replaces every nested
/// Java object, so any reference a caller took earlier silently detaches from
/// the value it was read out of, while still answering with the old contents.
/// Kotlin callers do not expect that from calling a method.
///
/// Conforming types update in place and recurse, so the whole object graph
/// keeps its identity and every existing reference observes the new values.
/// Only the leaves are replaced — a Java `String`, `byte[]` or boxed primitive
/// cannot be updated in place, and a reference to one staying at its old value
/// is what a Kotlin caller expects from an immutable value anyway.
///
/// The conformance is generated: serialized peers assign field by field, and
/// pointer-backed peers write through the address they already box, which also
/// avoids allocating a fresh native value per call.
public protocol JObjectUpdatable {
  /// Writes `self` into `obj`, which must be a Java object of this type's peer
  /// class. Nested peers are updated, not replaced.
  func updateJavaObject(_ obj: JavaObject)
}
