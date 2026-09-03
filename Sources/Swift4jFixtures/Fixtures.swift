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
public struct Leaf {
  public var label: String
  public var count: Int

  public init(label: String, count: Int) {
    self.label = label
    self.count = count
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
