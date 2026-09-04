import Foundation
import Swift4jHostMacros

/// Compiled with SWIFT4J_MACROS_ENABLED, so the real `@jvm` expansions run on
/// the host and the emitted thunks are type-checked by an ordinary build.
///
/// This target asserts nothing. Its value is that it compiles: every property
/// shape below produces a scoped-borrow thunk, a getter, a setter, a `copy_jni`
/// and a `deinit_jni`, and any of those failing to type-check is a build
/// failure here rather than a surprise in an Android build hours later.
///
/// The important case is `stamp`. `Date` bridges by conversion, so it has no
/// `fromUnownedPointer`, and its thunk only compiles because `_jvmScopedBorrow`
/// has a second overload for types that are merely `JObjectConvertible`.

@jvm
public struct Leaf: Hashable {
  public var label: String
  public var count: Int

  public init(label: String, count: Int) {
    self.label = label
    self.count = count
  }

  /// swift4j has no notion of `mutating`: this bridges to a plain `void`,
  /// indistinguishable from a read-only method. Where the write lands depends
  /// on how the receiver was obtained. Pinned in BridgeIntegrationTest.
  public mutating func bump() {
    count += 1
  }
}

@jvm
public struct Branch {
  // Pointer-boxed: resolves to the JvmPointerBoxed overload.
  public var leaf: Leaf

  // Conversion-bridged: resolves to the JObjectConvertible fallback.
  public var stamp: Date
  public var link: Foundation.URL

  // Excluded from scoped borrows, but still exercise getter/setter emission.
  public var name: String
  public var blob: Data
  public var count: Int
  public var flag: Bool
  public var optionalLeaf: Leaf?
  public var leaves: [Leaf]
  public var table: [String: Leaf]
  public let immutable: Leaf

  // Observer-only. `computed` is false for this, so it is selected — a scoped
  // borrow is an inout access, so didSet fires rather than being bypassed.
  public var observed: Leaf {
    didSet { }
  }

  // Computed: excluded, since there is no stored location to address.
  public var derived: Leaf { leaf }

  public init(leaf: Leaf, stamp: Date, link: Foundation.URL, name: String, blob: Data,
              count: Int, flag: Bool, optionalLeaf: Leaf?, leaves: [Leaf],
              table: [String: Leaf], immutable: Leaf, observed: Leaf) {
    self.leaf = leaf
    self.stamp = stamp
    self.link = link
    self.name = name
    self.blob = blob
    self.count = count
    self.flag = flag
    self.optionalLeaf = optionalLeaf
    self.leaves = leaves
    self.table = table
    self.immutable = immutable
    self.observed = observed
  }

  public func describe() -> String {
    return "\(name):\(count)"
  }

  public mutating func bump() {
    count += 1
  }
}

/// Small enough to construct from Java in one line, so the JVM integration
/// test can exercise borrow-writes and copy independence without building a
/// twelve-argument `Branch`.
@jvm
public struct Box {
  public var leaf: Leaf
  public var tag: String

  public init(leaf: Leaf, tag: String) {
    self.leaf = leaf
    self.tag = tag
  }
}

/// The shapes with no scoped borrow, so their writes go to a throwaway copy.
/// Present to pin that loss, not because it is wanted.
@jvm
public struct Lossy {
  public var leaf: Leaf
  public var maybe: Leaf?
  public var leaves: [Leaf]

  public init(leaf: Leaf, maybe: Leaf?, leaves: [Leaf]) {
    self.leaf = leaf
    self.maybe = maybe
    self.leaves = leaves
  }
}

/// Holds one of each kind so `copy()`'s depth can be observed: whether a nested
/// *value* detaches, and whether a nested *reference* stays shared.
@jvm
public struct Mixed {
  public var leaf: Leaf
  public var holder: Holder

  public init(leaf: Leaf, holder: Holder) {
    self.leaf = leaf
    self.holder = holder
  }
}

/// Counts its own observer firings, so a test can tell whether a write through
/// the bridge went through the property's setter or around it.
@jvm
public struct Observing {
  public var observerRuns: Int
  public var leaf: Leaf {
    didSet { observerRuns += 1 }
  }

  public init(leaf: Leaf) {
    self.observerRuns = 0
    self.leaf = leaf
  }
}

/// Simple enum: no associated values, so it bridges by ordinal rather than by
/// pointer box.
@jvm
public enum Color {
  case red
  case blue
}

/// Payload enum: its peer is a sealed hierarchy with a per-case factory, which
/// is why a pointer alone cannot say which case it holds.
@jvm
public enum Shape {
  case circle(radius: Int)
  case square(side: Int)
}

/// Enum-typed property, to see what a getter/setter looks like and whether it
/// can be scoped.
///
/// Only the simple enum is a property here. A payload-enum property would make
/// this file reference `Shape`, whose peer swift4j emits as **Kotlin**
/// (`Shape.kt`, a sealed class) while everything else is Java — so `javac`
/// alone cannot compile the peer set. `Shape` stays declared above because the
/// fixture target still type-checks its expansion; only the JVM harness has to
/// skip it.
@jvm
public struct Shaped {
  public var color: Color

  public init(color: Color) {
    self.color = color
  }
}

/// Classes take the reference path: no `copy_jni`, no `fromUnownedPtr`, and no
/// JvmPointerBoxed conformance.
@jvm
public class Holder {
  public var count: Int
  public var leaf: Leaf

  public init(count: Int, leaf: Leaf) {
    self.count = count
    self.leaf = leaf
  }
}

/// Namespaced type reference (`Nested.Inner`), which reaches the
/// MemberTypeSyntax branch of the scoped-borrow rule.
///
/// The namespace has to be an `extension`, not a nested type: nesting inside a
/// plain type is rejected ("Enclosing type is not exported"), while an
/// extension of a non-`@jvm` type is treated as a Java subpackage. This mirrors
/// how `Server.Subject` is declared in CaptureAPI.
public enum Nested { }

public extension Nested {
  @jvm
  struct Inner {
    public var value: Int
    public init(value: Int) { self.value = value }
  }
}

@jvm
public struct UsesNamespaced {
  public var inner: Nested.Inner
  public init(inner: Nested.Inner) { self.inner = inner }
}
