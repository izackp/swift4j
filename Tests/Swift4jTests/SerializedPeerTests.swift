import XCTest
import Foundation

@testable import swift4j_cli

/// Pins the Java surface for `@jvm(serialized: true)`: a peer carrying copied
/// fields instead of a `SwiftPtr`.
///
/// The negative assertions are the ones worth having. Everything that exists
/// only to own or borrow an address has to be gone, because a serialized peer
/// has no address — and each of those members would compile fine while being
/// meaningless.
final class SerializedPeerTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  @jvm
  public struct Inner {
    public var label: String
    public init(label: String) { self.label = label }
  }

  @jvm(serialized: true)
  public struct Snapshot {
    public var inner: Inner
    public var count: Int
    public var name: String?
    public var stamp: Date
    public var flag: Bool { count > 0 }
    public static var version: String = "1"
    public init(inner: Inner, count: Int, name: String?, stamp: Date) {
      self.inner = inner
      self.count = count
      self.name = name
      self.stamp = stamp
    }
    public func touch() {}
    public static func describe() -> String { "x" }
  }
  """

  private func generate() throws -> [String: String] {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-serialized-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    let generator = ProxyGenerator(package: "test.pkg", javaVersion: 11)
    var byType: [String: String] = [:]
    for result in try generator.run(paths: [file.path]) {
      for name in ["Inner", "Snapshot"] where result.source.contains("class \(name) ") {
        byType[name] = result.source
      }
    }
    return byType
  }

  func testSerializedPeerCarriesFieldsNotAPointer() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    XCTAssertTrue(snapshot.contains("private Inner inner;"))
    XCTAssertTrue(snapshot.contains("private long count;"))
    XCTAssertFalse(snapshot.contains("SwiftPtr"),
                   "a serialized peer holds no native memory")
  }

  func testGetterNamesAndTypesAreUnchanged() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    // The whole point: a consumer cannot tell this stopped being a handle.
    XCTAssertTrue(snapshot.contains("public Inner getInner()"))
    XCTAssertTrue(snapshot.contains("return inner;"))
    XCTAssertFalse(snapshot.contains("getInnerImpl"),
                   "a field read must not go through a native")
  }

  func testComputedPropertyBecomesAField() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    // Nothing can be lazy without a pointer, so a computed property is
    // evaluated once at marshal time or not exposed at all.
    XCTAssertTrue(snapshot.contains("private final boolean flag;"))
    XCTAssertTrue(snapshot.contains("public boolean getFlag()"))
  }

  func testAllFieldsConstructorIsPublicAndInDeclarationOrder() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    // The macro's toJavaObject builds its argument list from the same order,
    // so neither side may sort.
    XCTAssertTrue(snapshot.contains(
      "public Snapshot(Inner inner, long count, @Nullable String name, Date stamp, boolean flag)"))
  }

  /// `Objects.equals` on a primitive boxes both sides, and this runs per field
  /// per row on a diffing path.
  func testPrimitiveFieldsCompareWithoutBoxing() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    XCTAssertTrue(snapshot.contains("count == other.count"))
    XCTAssertTrue(snapshot.contains("flag == other.flag"))
    XCTAssertTrue(snapshot.contains("java.util.Objects.equals(inner, other.inner)"),
                  "reference fields still need null-safe equality")
  }

  func testNothingThatOwnsOrBorrowsAnAddressSurvives() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    for member in ["_ptr", "deinit", "copyImpl", "fromUnownedPtr",
                   "Borrowed", "unsafeWith", "_cache", "_attachCache"] {
      XCTAssertFalse(snapshot.contains(member),
                     "\(member) has no meaning without an address")
    }
  }

  /// The edit-buffer pattern is copy, mutate, hand back — so a serialized peer
  /// has to be writable. A read-only Swift declaration has nothing to write to
  /// and stays final.
  func testMutablePropertiesGetSettersAndReadOnlyOnesDoNot() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    XCTAssertTrue(snapshot.contains("public void setCount(long value)"))
    XCTAssertTrue(snapshot.contains("this.count = value;"))
    XCTAssertTrue(snapshot.contains("private long count;"),
                  "a settable field cannot be final")

    XCTAssertFalse(snapshot.contains("setFlag"),
                   "a get-only computed property has no storage to write")
    XCTAssertTrue(snapshot.contains("private final boolean flag;"))
  }

  /// An instance setter writes a Java field and does not reach through a
  /// pointer, so marking it @SwiftMutating would claim something false. A
  /// *static* setter still does write Swift storage and keeps the marker —
  /// which is why this counts rather than just searching.
  func testOnlyTheStaticSetterIsMarkedSwiftMutating() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    let marks = snapshot.components(separatedBy: "SwiftMutating").count - 1
    XCTAssertEqual(marks, 1,
                   "exactly one @SwiftMutating, on the static setter")
    XCTAssertTrue(snapshot.contains("setVersion"),
                  "the static property keeps its native-backed setter")
  }

  /// A static has no receiver to have been marshalled, so it stays
  /// native-backed. An instance method survives too, as a native taking no
  /// pointer: JNI passes the peer as the receiver and the thunk rebuilds the
  /// Swift value from the marshalled fields.
  func testStaticsAndInstanceMethodsBothSurvive() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    XCTAssertTrue(snapshot.contains("getVersion"), "a static property survives")
    XCTAssertTrue(snapshot.contains("describe"), "a static method survives")
    XCTAssertTrue(snapshot.contains("touch"), "an instance method survives")
  }

  /// The shape of the surviving instance method: no `long ptr` anywhere, since
  /// there is no address to pass and `_ptr()` does not exist on this peer.
  func testInstanceMethodNativeTakesNoPointer() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    XCTAssertTrue(snapshot.contains("native void touchImpl()"),
                  "the native takes only the declared parameters")
    XCTAssertFalse(snapshot.contains("touchImpl(_ptr()"),
                   "a serialized peer has no _ptr() to pass")
  }

  func testClassInitSurvives() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    // The macro emits the peer that calls this unconditionally, so it must
    // exist even when the registered native set is empty.
    XCTAssertTrue(snapshot.contains("private static native void Snapshot_class_init();"))
  }

  func testValueEqualityIsGenerated() throws {
    let snapshot = try XCTUnwrap(generate()["Snapshot"])

    XCTAssertTrue(snapshot.contains("public boolean equals(Object o)"))
    XCTAssertTrue(snapshot.contains("public int hashCode()"))
  }

  /// The unannotated type in the same file must be untouched, or this feature
  /// is a regression for every existing `@jvm` type.
  func testUnannotatedTypeIsUnchanged() throws {
    let inner = try XCTUnwrap(generate()["Inner"])

    XCTAssertTrue(inner.contains("private final SwiftPtr _ptr;"))
    XCTAssertTrue(inner.contains("public Inner copy()"))
    XCTAssertTrue(inner.contains("public static final class Borrowed"))
  }
}
