import XCTest
import Foundation

@testable import swift4j_cli

/// Pins the Java surface swift4j-cli emits for scoped borrows and `copy()`.
///
/// The interesting assertion is the negative one. `Date` bridges by conversion,
/// so there is no address for a peer to wrap — but the macro still registers a
/// native for it, because it cannot resolve what a type name refers to. The CLI
/// therefore has to *declare* that native (or RegisterNatives unbinds the whole
/// class) while exposing no public wrapper for it. Getting only half of that
/// right is silent until the app runs.
final class GeneratedPeerTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  @jvm
  public struct Inner {
    public var label: String
    public init(label: String) { self.label = label }
  }

  @jvm
  public struct Outer {
    public var inner: Inner
    public var modifiedAt: Date
    public var count: Int
    public init(inner: Inner, modifiedAt: Date, count: Int) {
      self.inner = inner
      self.modifiedAt = modifiedAt
      self.count = count
    }
  }

  @jvm
  public class Holder {
    public var count: Int
    public init(count: Int) { self.count = count }
  }
  """

  private func generate() throws -> [String: String] {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-peer-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    let generator = ProxyGenerator(package: "test.pkg", javaVersion: 11)
    var byType: [String: String] = [:]
    for result in try generator.run(paths: [file.path]) {
      for name in ["Inner", "Outer", "Holder"] where result.source.contains("class \(name) ") {
        byType[name] = result.source
      }
    }
    return byType
  }

  func testPointerBoxedPropertyGetsAPublicScope() throws {
    let generated = try generate()
    let outer = try XCTUnwrap(generated["Outer"])
    let inner = try XCTUnwrap(generated["Inner"])

    // The scope yields `Inner.Borrowed`, not `Inner`. That distinct type is what
    // makes storing the view a compile error rather than a latent crash.
    XCTAssertTrue(outer.contains("public void unsafeWithInner(io.scade.swift4j.SwiftBorrow<Inner.Borrowed> body)"),
                  "a @jvm struct property should expose a scoped borrow of the Borrowed type")
    XCTAssertTrue(inner.contains("public static final class Borrowed"),
                  "a @jvm struct should generate its Borrowed view type")
    XCTAssertTrue(inner.contains("public void invalidate()"),
                  "the view must be invalidatable, so use-after-scope throws")
    XCTAssertTrue(outer.contains("private native void unsafeWithInnerImpl(long ptr,"),
                  "the native backing it must be declared")
  }

  func testConversionBridgedPropertyDeclaresTheNativeButExposesNothing() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertTrue(outer.contains("private native void unsafeWithModifiedAtImpl(long ptr,"),
                  "the macro registers this native, so the Java method must exist "
                  + "or RegisterNatives unbinds every native on the class")
    XCTAssertFalse(outer.contains("public void unsafeWithModifiedAt("),
                  "Date has no interior pointer to borrow; exposing a scope for it "
                  + "would hand callers a copy while naming it a borrow")
  }

  func testPrimitivePropertyGetsNoScopeAtAll() throws {
    let outer = try XCTUnwrap(generate()["Outer"])
    XCTAssertFalse(outer.contains("unsafeWithCount"),
                   "primitives are excluded by both generators, natives included")
  }

  func testValueTypesGetCopyAndClassesDoNot() throws {
    let generated = try generate()
    let outer = try XCTUnwrap(generated["Outer"])
    let holder = try XCTUnwrap(generated["Holder"])

    XCTAssertTrue(outer.contains("public Outer copy()"))
    XCTAssertTrue(outer.contains("private native long copyImpl(long ptr);"))
    XCTAssertTrue(outer.contains("private static Outer fromUnownedPtr(long ptr)"))

    // A class's peer already refers to one Swift object, so copying it would
    // mean something else entirely, and there is no inline storage to wrap.
    XCTAssertFalse(holder.contains("copy()"))
    XCTAssertFalse(holder.contains("fromUnownedPtr"))
  }
}
