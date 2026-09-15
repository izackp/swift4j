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

/// Enum-typed properties, to see what a getter/setter looks like for each kind
/// and whether either can be scoped.
///
/// `shape` makes this file reference `Shape`, whose peer swift4j emits as
/// **Kotlin** (`Shape.kt`, a sealed class) while everything else is Java. The
/// harness therefore has to compile Kotlin before Java.
@jvm
public struct Shaped {
  public var color: Color
  public var shape: Shape

  public init(color: Color, shape: Shape) {
    self.color = color
    self.shape = shape
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


// MARK: - Serialized peers

/// `@jvm(serialized: true)`: the Java peer carries copied fields instead of a
/// `SwiftPtr`, so it holds no native memory and ordinary Java GC reclaims it.
///
/// This target asserts nothing, and that is the point — `toJavaObject` here
/// calls a constructor whose JNI descriptor the macro builds from the property
/// types. A descriptor that does not type-check, or a property type with no
/// `toJavaParameter`, is a build failure at this line instead of an
/// `UnsatisfiedLinkError` on a device.
///
/// Covers the shapes that differ: a primitive, a `String?`, a conversion-bridged
/// `Date`, a nested *handle* peer (`Leaf`, which still boxes a pointer), a
/// nested *serialized* peer (`SerializedLeaf`, which recurses into its own
/// copy), a get-only computed property (evaluated once at marshal time, and
/// final on the Java side), and a static (which keeps its native, because it
/// has no receiver to have been marshalled).
@jvm(serialized: true)
public struct SerializedLeaf {
  public var label: String
  public var weight: Double

  public init(label: String, weight: Double) {
    self.label = label
    self.weight = weight
  }

  /// A `mutating` method on a peer with no pointer. The receiver is rebuilt
  /// from the peer's fields, so the write has to be copied back through the
  /// peer's setters or it would land on the temporary and vanish. Every
  /// property here marshals and is `var`, which is what allows it.
  public mutating func rename(to newLabel: String) {
    label = newLabel
  }

  /// Mutates *and* returns, to pin that the copy-back runs after the return
  /// value is computed rather than instead of it.
  public mutating func scale(by factor: Double) -> Double {
    weight *= factor
    return weight
  }
}

/// Unmarshalled storage a reconstruction can still recover: `blob` is
/// `@nonjvm` and `Optional`, so it never crosses and rebuilds as `nil`. Absence
/// is the one value that cannot be mistaken for a real one, so the type stays
/// reconstructible. This is the `LocalImage.thumbnail` shape.
@jvm(serialized: true)
public struct SerializedPartial {
  public var label: String
  @nonjvm public var blob: Data?

  public init(label: String, blob: Data? = nil) {
    self.label = label
    self.blob = blob
  }
}

/// Optional primitives. `Optional` conforms to `JParameterConvertible` only
/// where `Wrapped: JObjectConvertible`, so these have no `toJavaParameter()`
/// witness and must be boxed on the way out. This is the
/// `Server.Subject.period` shape.
@jvm(serialized: true)
public struct SerializedOptionalPrimitives {
  public var count: Int32?
  public var size: Int64?
  public var ratio: Double?
  public var flag: Bool?
  public var label: String?

  public init(count: Int32?, size: Int64?, ratio: Double?, flag: Bool?, label: String?) {
    self.count = count
    self.size = size
    self.ratio = ratio
    self.flag = flag
    self.label = label
  }
}

@jvm(serialized: true)
public struct SerializedRow {
  public var id: Int
  public var name: String?
  public var stamp: Date
  public var handleLeaf: Leaf
  public var serializedLeaf: SerializedLeaf
  public var flag: Bool { id > 0 }

  public static var schemaVersion: Int = 1

  public init(id: Int, name: String?, stamp: Date, handleLeaf: Leaf, serializedLeaf: SerializedLeaf) {
    self.id = id
    self.name = name
    self.stamp = stamp
    self.handleLeaf = handleLeaf
    self.serializedLeaf = serializedLeaf
  }

  public static func describe() -> String { "row" }

  /// Instance methods on a serialized peer. The native takes no pointer; JNI
  /// passes the peer as the receiver and the thunk rebuilds this value from the
  /// marshalled fields, so `self` here is a copy reconstructed per call. Reads
  /// a nested serialized member and a nested *handle* member to prove the
  /// reconstruction recurses through both.
  public func summarize() -> String {
    "\(id):\(name ?? "-"):\(handleLeaf.label):\(serializedLeaf.label)"
  }

  public func scaled(by factor: Double) -> Double {
    serializedLeaf.weight * factor
  }
}

/// Entry points for the JVM round-trip test. Compiling the fixtures proves the
/// expansion type-checks; only running these proves the constructor descriptor,
/// the argument order and the nested conversions are actually right.
@jvm
public class SerializedBridge {

  public static func makeRow() -> SerializedRow {
    return SerializedRow(
      id: 42,
      name: "hello",
      stamp: Date(timeIntervalSince1970: 1_700_000_000),
      handleLeaf: Leaf(label: "leaf", count: 7),
      serializedLeaf: SerializedLeaf(label: "inner", weight: 2.5))
  }

  public static func makeOptionalPrimitives(present: Bool) -> SerializedOptionalPrimitives {
    guard present else {
      return SerializedOptionalPrimitives(
        count: nil, size: nil, ratio: nil, flag: nil, label: nil)
    }
    return SerializedOptionalPrimitives(
      count: -7, size: 9_000_000_000, ratio: 0.25, flag: true, label: "set")
  }

  public static func sumOptionalPrimitives(_ v: SerializedOptionalPrimitives) -> Int64 {
    return Int64(v.count ?? 0) + (v.size ?? 0)
  }

  public static func makeRowWithNilName() -> SerializedRow {
    return SerializedRow(
      id: 0,
      name: nil,
      stamp: Date(timeIntervalSince1970: 0),
      handleLeaf: Leaf(label: "", count: 0),
      serializedLeaf: SerializedLeaf(label: "", weight: 0))
  }

  /// Java -> Swift. Renders what Swift actually received, so a field that
  /// arrives in the wrong slot is visible rather than merely unequal.
  public static func describe(_ row: SerializedRow) -> String {
    return "id=\(row.id)"
      + " name=\(row.name ?? "nil")"
      + " stamp=\(Int(row.stamp.timeIntervalSince1970))"
      + " handleLeaf=\(row.handleLeaf.label):\(row.handleLeaf.count)"
      + " serializedLeaf=\(row.serializedLeaf.label):\(row.serializedLeaf.weight)"
      + " flag=\(row.flag)"
  }

  /// Round-trips a value the Java side mutated, which is the edit-buffer shape:
  /// copy out, write fields, hand back.
  public static func idAfterEdit(_ row: SerializedRow) -> Int {
    return row.id
  }

  public static func makeOpaque() -> Opaque {
    return Opaque(raw: 1234567890123)
  }

  /// Goes through the hand-written `fromJavaObject`, so it proves the storage
  /// behind the marshalled facade was actually recovered.
  public static func opaqueRaw(_ value: Opaque) -> String {
    return String(value.raw)
  }
}

/// A pointer-backed type holding a *serialized* member.
///
/// The scoped-borrow rule is syntactic: both generators see `SerializedLeaf` as
/// a bare type name and register/declare `unsafeWithLeafImpl` for it. But a
/// serialized peer has no `Borrowed` view to hand out and no
/// `fromUnownedPointer` to build one from, so the Java wrapper is suppressed
/// and the Swift thunk has to fall through to the `JObjectConvertible`
/// overload of `_jvmScopedBorrow` — the same path `Date` takes.
///
/// Compiling this is the check. Without that overload it is a type error here.
@jvm
public struct HoldsSerialized {
  public var leaf: SerializedLeaf
  public var optionalLeaf: SerializedLeaf?
  public var leaves: [SerializedLeaf]

  public init(leaf: SerializedLeaf, optionalLeaf: SerializedLeaf?, leaves: [SerializedLeaf]) {
    self.leaf = leaf
    self.optionalLeaf = optionalLeaf
    self.leaves = leaves
  }
}

/// The `LcUUID` shape: all marshalled members are computed, and the only
/// storage is opted out of bridging. The macro cannot generate a
/// reconstruction — it would assign defaults and hand back a valid-looking
/// value for the wrong thing — so it emits none, and the author supplies one.
///
/// Compiling this proves the escape hatch works at all: the macro adds a
/// `: JObjectConvertible` conformance whose `fromJavaObject` requirement is
/// satisfied from a *separate* extension, which is the only reason a
/// hand-written conversion can coexist with a generated `toJavaObject`.
@jvm(serialized: true)
public struct Opaque {
  @nonjvm public private(set) var raw: UInt64

  public var text: String { String(raw) }

  @nonjvm public init(raw: UInt64) {
    self.raw = raw
  }
}

extension Opaque {
  private enum __JavaMethods__ {
    static let getText: JavaMethodID = {
      guard let mid = Opaque.javaClass.getMethodID(name: "getText", sig: "()Ljava/lang/String;") else {
        fatalError("Could not find Opaque.getText")
      }
      return mid
    } ()
  }

  /// Reads the marshalled surface and rebuilds the storage behind it. Resolved
  /// method id, not a string-keyed lookup: this runs once per value crossing.
  public static func fromJavaObject(_ obj: JavaObject?) -> Opaque {
    guard let obj else {
      fatalError("Opaque.fromJavaObject received null")
    }
    let text: String = JObject(obj).call(method: __JavaMethods__.getText)
    guard let raw = UInt64(text) else {
      fatalError("Opaque.fromJavaObject: could not parse \(text)")
    }
    return Opaque(raw: raw)
  }
}


/// Reproduces the macro/CLI split that no compiler can see.
///
/// The CLI reads every file, so it attaches `extension ExtensionStatic` and
/// emits a Java `native orphanedStaticImpl`. The macro is attached to the
/// struct and cannot see extensions, so it registers nothing for it. The
/// RegisterNatives batch still succeeds — only entries that are *passed* get
/// validated — so the class loads clean and `orphanedStatic` throws
/// UnsatisfiedLinkError whenever it is first called, which may be never.
@jvm
public struct ExtensionStatic {
  public var id: Int64

  public init(id: Int64) {
    self.id = id
  }
}

public extension ExtensionStatic {
  // Explicitly `public`: the CLI's export test reads the modifier on the
  // declaration, not the effective access level the extension confers.
  public static func orphanedStatic(_ value: Int64) -> Int64 {
    return value * 2
  }
}


/// Hands the registration check's findings to the JVM side so a test can
/// assert on them. They are also printed to `System.err` for a human.
@jvm
public class NativeCheckBridge {
  public static func findings() -> [String] {
    return NativeRegistrationCheck.findings
  }

  /// Touching a class is what runs its `class_init`, and therefore its check.
  public static func loadExtensionStatic() -> Int64 {
    return ExtensionStatic(id: 7).id
  }
}
