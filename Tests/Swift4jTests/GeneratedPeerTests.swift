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
    public var inners: [Inner]
    public var stamps: [Date]
    public init(inner: Inner, modifiedAt: Date, count: Int, inners: [Inner], stamps: [Date]) {
      self.inner = inner
      self.modifiedAt = modifiedAt
      self.count = count
      self.inners = inners
      self.stamps = stamps
    }
  }

  @jvm
  public class Holder {
    public static var shared: String = "x"
    public var count: Int
    public init(count: Int) { self.count = count }
    public func bump() {}
    public func each(_ body: (Int) -> Void) {}
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

  // MARK: - D8: peer lock

  func testInstanceAccessorsAreGuarded() throws {
    let holder = try XCTUnwrap(generate()["Holder"])

    XCTAssertTrue(holder.contains(
      "public  long getCount() {\n"
      + "    synchronized (_ptr) {\n"
      + "      return this.getCountImpl(_ptr());\n"
      + "    }\n"
      + "  }"),
      "an instance getter must serialise on the peer, or a concurrent setter's "
      + "release can land between this read's load and its retain")

    XCTAssertTrue(holder.contains("synchronized (_ptr) {\n      this.setCountImpl("),
                  "an instance setter must serialise on the peer")
    XCTAssertTrue(holder.contains("synchronized (_ptr) {\n      this.bumpImpl("),
                  "a mutating method writes fields, so it needs the same guard")
  }

  func testStaticsAndClosureTakingMethodsAreNotGuarded() throws {
    let holder = try XCTUnwrap(generate()["Holder"])

    XCTAssertTrue(holder.contains(
      "public static String getShared() {\n"
      + "    return Holder.getSharedImpl();\n"
      + "  }"),
      "a static has no instance to lock on")

    XCTAssertTrue(holder.contains(
      "public  void each(Consumer<Long> body)  {\n"
      + "    this.eachImpl(_ptr(), body);\n"
      + "  }"),
      "the closure runs inside the native call and can take JVM monitors; "
      + "guarding it would let a Swift lock deadlock against a Java one")
  }

  func testBorrowedForwardingIsNotGuarded() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    // The owner's scope already holds the monitor for the whole callback.
    // Re-taking it per view access would be redundant, and locking the *view's*
    // own peer instead would exclude nothing, since the storage belongs to the
    // owner.
    let start = try XCTUnwrap(outer.range(of: "public static final class Borrowed"))
    let end = try XCTUnwrap(outer.range(of: "public static Borrowed wrapBorrowed"))
    let body = outer[start.lowerBound..<end.lowerBound]
    XCTAssertFalse(body.contains("synchronized"),
                   "the owner's scope holds the monitor; the view must not "
                   + "take one of its own")
  }

  func testScopeHoldsTheMonitorAndRejectsNesting() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    // Per-access locking inside the scope would not be enough: the interior
    // pointer stays live across the callback, so the monitor has to span it.
    XCTAssertTrue(outer.contains(
      "public void unsafeWithInner(io.scade.swift4j.SwiftBorrow<Inner.Borrowed> body) {\n"
      + "    synchronized (_ptr) {"),
      "the scope must hold the owner's monitor across the whole callback")

    XCTAssertTrue(outer.contains("private boolean _inScope;"),
                  "nesting detection needs the flag on the owner")
    XCTAssertTrue(outer.contains("if (_inScope) {"),
                  "monitors are reentrant, so a nested scope on the same peer "
                  + "would otherwise hand out a second view of one storage")
    XCTAssertTrue(outer.contains("_inScope = false;"),
                  "the flag must clear on the way out, including on throw")
  }

  func testAccessorsAreSealedWhileAScopeIsOpen() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertTrue(outer.contains(
      "public  long getCount() {\n"
      + "    synchronized (_ptr) {\n"
      + "      if (_inScope) {"),
      "an ordinary read during a scope conflicts with the exclusive access the "
      + "scope holds, and nothing in Swift catches it through a raw pointer")

    // A write detaches from any cache holding this peer before it touches the
    // monitor, so a cache can never report back a write Swift did not see.
    XCTAssertTrue(outer.contains(
      "public  void setCount(long value) {\n"
      + "    _detachCache();\n"
      + "    synchronized (_ptr) {\n"
      + "      if (_inScope) {"),
      "the same applies to writes")
  }

  func testArrayOfJvmStructsGetsAForEachScope() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertTrue(outer.contains("public void unsafeForEachInners(io.scade.swift4j.SwiftBorrow<Inner.Borrowed> body)"),
                  "an array of a @jvm struct yields its elements, not the array — "
                  + "[T] has no bridged peer to hand out")
    XCTAssertTrue(outer.contains("private native void unsafeForEachInnersImpl(long ptr,"),
                  "the native backing it must be declared")

    // Same split as the scalar case: the macro registers the native from
    // syntax alone, so the CLI must declare it even where it exposes nothing.
    XCTAssertTrue(outer.contains("private native void unsafeForEachStampsImpl(long ptr,"),
                  "an array of a conversion-bridged element still registers, or "
                  + "RegisterNatives unbinds every native on the class")
    XCTAssertFalse(outer.contains("public void unsafeForEachStamps("),
                   "Date elements have no interior pointer to hand out")
  }

  func testArraysGetConstantTimeIndexedAccess() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertTrue(outer.contains("public Inner getInnersAt(int index)"),
                  "reaching one element must not depend on the array's length")
    XCTAssertTrue(outer.contains("public void unsafeElementOfInners(int index, io.scade.swift4j.SwiftBorrow<Inner.Borrowed> body)"),
                  "and the same index must be writable in place")
    XCTAssertTrue(outer.contains("public int sizeOfInners()"),
                  "a caller needs the length without marshalling the array to get it")

    XCTAssertTrue(outer.contains("private native void unsafeElementOfInnersImpl(long ptr, int index,"))
    XCTAssertTrue(outer.contains("private native int sizeOfInnersImpl(long ptr);"))

    // The Swift side runs the body zero times for an index it does not hold,
    // which would otherwise surface as a null rather than as a bounds error.
    XCTAssertTrue(outer.contains("throw new IndexOutOfBoundsException("))
  }

  func testConversionBridgedArrayDeclaresTheNativesButExposesNothing() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertTrue(outer.contains("private native int sizeOfStampsImpl(long ptr);"),
                  "registered by the macro from syntax alone, so it must be declared")
    XCTAssertFalse(outer.contains("public Date getStampsAt("),
                   "a Date element has no interior pointer to copy out of")
  }

  // MARK: - Property cache

  func testStructPropertiesAreCachedAndEveryWritePathInvalidates() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertTrue(outer.contains("class Outer implements io.scade.swift4j.SwiftCacheOwner"))
    XCTAssertTrue(outer.contains("private Inner _cacheInner;"))
    XCTAssertTrue(outer.contains("fresh._attachCache(this, 0);"),
                  "the cached child must know where it is held, so its own "
                  + "writes can clear the entry")

    // Every write path, because missing one turns a lost write into a write
    // that the next read reports back while Swift never saw it.
    XCTAssertTrue(outer.contains("      _cacheInner = null;\n      this.setInnerImpl("),
                  "replacing the property drops its cached peer")
    XCTAssertTrue(outer.contains("        _cacheInner = null;\n      }"),
                  "a scope may have written through the view, so it drops on exit")
    XCTAssertTrue(outer.contains("case 0: _cacheInner = null; break;"),
                  "and the child can clear the entry from its own setters")
  }

  func testConversionBridgedAndPrimitivePropertiesAreNotCached() throws {
    let outer = try XCTUnwrap(generate()["Outer"])

    XCTAssertFalse(outer.contains("_cacheModifiedAt"),
                   "Date bridges by conversion, so there is no peer to cache")
    XCTAssertFalse(outer.contains("_cacheCount"),
                   "a primitive never marshalled a box in the first place")
  }

  func testClassPeersGetNoCache() throws {
    let holder = try XCTUnwrap(generate()["Holder"])

    // Swift owns the object and can mutate it with no bridge involvement, so
    // there is no point at which the cache could be invalidated.
    XCTAssertFalse(holder.contains("SwiftCacheOwner"))
    XCTAssertFalse(holder.contains("_detachCache"))
    XCTAssertFalse(holder.contains("_attachCache"))
  }

  func testMutatingMethodsInvalidateToo() throws {
    let inner = try XCTUnwrap(generate()["Inner"])

    // Nothing in a Java signature says whether a method writes, so detaching is
    // unconditional on value peers.
    XCTAssertTrue(inner.contains("public void _attachCache("),
                  "any value peer can be cached by an owner")
  }

  func testTypesWithoutAScopeGetNoScopeFlag() throws {
    let inner = try XCTUnwrap(generate()["Inner"])
    XCTAssertFalse(inner.contains("_inScope"),
                   "Inner exposes no unsafeWith, so the flag would be dead weight")
  }
}
