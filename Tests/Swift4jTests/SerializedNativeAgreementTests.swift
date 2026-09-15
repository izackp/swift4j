import XCTest
import Foundation
import SwiftSyntax
import SwiftParser
import SwiftSyntaxExtensions

@testable import Swift4jMacros
@testable import swift4j_cli

/// The macro registers natives and swift4j-cli declares them, and the two share
/// no code. `RegisterNatives` fails the *whole batch* when a registered native
/// has no matching Java method — which unbinds every native on the class and
/// throws on first use, from a green build.
///
/// Serialized peers make that risk sharper rather than smaller. Almost every
/// native disappears, so the two sides now have to agree about a large set of
/// *absences*: accessors, `deinit`, `copyImpl`, the borrow thunks and the
/// Hashable bridge. Missing one on either side is invisible until a device runs.
final class SerializedNativeAgreementTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  @jvm
  public struct Handle: Hashable {
    public var label: String
    public init(label: String) { self.label = label }
  }

  @jvm(serialized: true)
  public struct Row: Hashable {
    public var id: Int
    public var name: String?
    public var stamp: Date
    public var handle: Handle
    public var flag: Bool { id > 0 }

    public static var schemaVersion: Int = 1

    public init(id: Int, name: String?, stamp: Date, handle: Handle) {
      self.id = id
      self.name = name
      self.stamp = stamp
      self.handle = handle
    }

    public func touch() {}
    public static func describe() -> String { "row" }
  }

  /// A pointer-backed type holding a serialized member. Both generators see
  /// `Row` as a bare name and agree to register a borrow native for it; only
  /// the CLI knows the peer has no `Borrowed` view, so it declares the native
  /// and suppresses the public wrapper.
  /// Not reconstructible: `blob` is `@nonjvm`, so the Java value does not carry
  /// it and no rebuild can produce it. Every instance method is refused, not
  /// just the `mutating` one.
  @jvm(serialized: true)
  public struct PartlyMarshalled {
    public var label: String
    @nonjvm public var blob: Data?
    public init(label: String, blob: Data? = nil) {
      self.label = label
      self.blob = blob
    }
    public func describe() -> String { label }
    public mutating func wipe() { blob = nil }
  }

  /// Reconstructible and fully marshalled, but `id` is a `let`, so the peer
  /// declares no setter to write it back through.
  @jvm(serialized: true)
  public struct Frozen {
    public let id: Int
    public var label: String
    public init(id: Int, label: String) {
      self.id = id
      self.label = label
    }
    public mutating func retitle(_ v: String) { label = v }
  }

  /// Not reconstructible: `raw` is `@nonjvm` and not Optional, so the macro
  /// emits no `fromJavaObject` and an instance method has nothing to rebuild a
  /// receiver from. Both sides must therefore still drop `describeRaw`.
  @jvm(serialized: true)
  public struct Sealed {
    @nonjvm public var raw: UInt64
    public var text: String { String(raw) }
    @nonjvm public init(raw: UInt64) { self.raw = raw }
    public func describeRaw() -> String { text }
    public static func kind() -> String { "sealed" }
  }

  @jvm
  public struct Holder {
    public var row: Row
    public var maybeRow: Row?
    public init(row: Row, maybeRow: Row?) {
      self.row = row
      self.maybeRow = maybeRow
    }
  }
  """

  /// Native names the macro will hand to `RegisterNatives`.
  private func macroRegisteredNatives(forTypeNamed wanted: String) throws -> Set<String> {
    let source = Parser.parse(source: Self.fixture)
    for stmt in source.statements {
      guard let decl = stmt.item.as(StructDeclSyntax.self), decl.typeName == wanted else { continue }
      let entries = try decl.expandCreateNativeMethods(parents: [], namespacePath: [])
      return Set(entries.compactMap { entry in
        // `JNINativeMethod2(name: "foo", sig: ...)`
        guard let open = entry.range(of: "name: \""),
              let close = entry.range(of: "\"", range: open.upperBound..<entry.endIndex) else { return nil }
        return String(entry[open.upperBound..<close.lowerBound])
      })
    }
    XCTFail("fixture has no struct named \(wanted)")
    return []
  }

  /// Native methods the generated Java declares, minus the class-init entry
  /// point — that one is bound by JNI name lookup from `@_cdecl`, not through
  /// `RegisterNatives`, so it deliberately has no counterpart in the macro set.
  private func javaDeclaredNatives(forTypeNamed wanted: String) throws -> Set<String> {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-agreement-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    let generator = ProxyGenerator(package: "test.pkg", javaVersion: 11)
    var java: String?
    for result in try generator.run(paths: [file.path])
    where result.source.contains("class \(wanted) ") {
      java = result.source
    }
    let source = try XCTUnwrap(java, "generator produced no peer for \(wanted)")

    var names: Set<String> = []
    for rawLine in source.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.contains(" native "), let paren = line.firstIndex(of: "(") else { continue }
      guard let nameStart = line[line.startIndex..<paren].lastIndex(of: " ") else { continue }
      let name = String(line[line.index(after: nameStart)..<paren])
      guard name != "\(wanted)_class_init" else { continue }
      names.insert(name)
    }
    return names
  }

  /// The invariant. Any drift between the two implementations fails here.
  func testSerializedTypeRegistersExactlyWhatItsPeerDeclares() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Row")
    let declared = try javaDeclaredNatives(forTypeNamed: "Row")

    XCTAssertEqual(registered, declared,
                   "registered-but-not-declared: \(registered.subtracting(declared)); "
                   + "declared-but-not-registered: \(declared.subtracting(registered))")
  }

  /// Same check for a pointer-backed type in the same file, so the serialized
  /// branch cannot be shown to agree by having quietly broken the other path.
  func testHandleTypeStillRegistersExactlyWhatItsPeerDeclares() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Handle")
    let declared = try javaDeclaredNatives(forTypeNamed: "Handle")

    XCTAssertEqual(registered, declared,
                   "registered-but-not-declared: \(registered.subtracting(declared)); "
                   + "declared-but-not-registered: \(declared.subtracting(registered))")
  }

  /// The edge the borrow rule cannot see. `Holder.row` is a serialized type, so
  /// its peer has no `Borrowed`, no `wrapBorrowed` and no `_attachCache` — but
  /// both generators decide borrowability from the type *name*. The native has
  /// to stay declared (or RegisterNatives unbinds the class) while the public
  /// wrapper and the cache field are suppressed.
  func testHandleHoldingASerializedMemberStillAgrees() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Holder")
    let declared = try javaDeclaredNatives(forTypeNamed: "Holder")

    XCTAssertTrue(registered.contains("unsafeWithRowImpl"),
                  "the macro registers this from syntax alone")
    XCTAssertEqual(registered, declared,
                   "registered-but-not-declared: \(registered.subtracting(declared)); "
                   + "declared-but-not-registered: \(declared.subtracting(registered))")
  }

  func testNoBorrowViewIsNamedForASerializedMember() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-holder-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    let generator = ProxyGenerator(package: "test.pkg", javaVersion: 11)
    var holder: String?
    for result in try generator.run(paths: [file.path])
    where result.source.contains("class Holder ") {
      holder = result.source
    }
    let source = try XCTUnwrap(holder)

    XCTAssertFalse(source.contains("Row.Borrowed"),
                   "a serialized peer declares no Borrowed view")
    XCTAssertFalse(source.contains("Row.wrapBorrowed"))
    XCTAssertFalse(source.contains("_cacheRow"),
                   "the cache calls _attachCache, which a serialized peer lacks")
    XCTAssertTrue(source.contains("unsafeWithRowImpl"),
                  "the native stays declared even with no caller")
  }

  /// Names the absences explicitly. The equality test above would catch these,
  /// but it reports a set difference; this says which member came back.
  func testNoPointerNativesSurviveSerialization() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Row")

    for gone in ["deinit", "copyImpl", "init0",
                 "getIdImpl", "getNameImpl", "getHandleImpl", "getFlagImpl",
                 "unsafeWithHandleImpl",
                 "equalsImpl", "hashCodeImpl"] {
      XCTAssertFalse(registered.contains(gone),
                     "\(gone) has no meaning on a peer with no address")
    }
  }

  /// An instance method is the one member that survives without a pointer: its
  /// native takes none, JNI supplies the peer as the receiver, and the thunk
  /// rebuilds the Swift value from the marshalled fields. `Row` is
  /// reconstructible, so `touch` stays.
  func testInstanceMethodsSurviveOnAReconstructiblePeer() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Row")
    let declared = try javaDeclaredNatives(forTypeNamed: "Row")

    XCTAssertTrue(registered.contains("touchImpl"),
                  "a reconstructible serialized peer dispatches instance methods")
    XCTAssertTrue(declared.contains("touchImpl"),
                  "and the Java side must declare the same native")
  }

  /// The gate on the above. Without a reconstruction there is no receiver to
  /// dispatch on, so the instance method goes and the static stays — and, more
  /// importantly, both sides make that call identically.
  func testInstanceMethodsStayDroppedOnANonReconstructiblePeer() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Sealed")
    let declared = try javaDeclaredNatives(forTypeNamed: "Sealed")

    XCTAssertFalse(registered.contains("describeRawImpl"),
                   "nothing can rebuild the receiver, so the method cannot be bridged")
    XCTAssertTrue(registered.contains("kindImpl"), "a static is unaffected")
    XCTAssertEqual(registered, declared,
                   "registered-but-not-declared: \(registered.subtracting(declared)); "
                   + "declared-but-not-registered: \(declared.subtracting(registered))")
  }

  /// Two separate gates, asserted separately.
  ///
  /// An unmarshalled stored property blocks *every* instance method, read or
  /// write: the thunk rebuilds the receiver from the peer's fields, and a field
  /// that never crossed cannot be rebuilt from. It used to rebuild as `nil`
  /// when it was `Optional`, which let reads through at the cost of handing
  /// them a receiver that differed from the value marshalled out.
  ///
  /// A `let` is narrower — the value crosses intact, so reads are fine; only
  /// the write has no setter to go back through.
  func testMutatingIsRefusedWhereTheWriteCannotBeCopiedBack() throws {
    let partial = try macroRegisteredNatives(forTypeNamed: "PartlyMarshalled")
    XCTAssertFalse(partial.contains("describeImpl"),
                   "the receiver cannot be rebuilt, so even a read is refused")
    XCTAssertFalse(partial.contains("wipeImpl"),
                   "and a write to it has no field to land in")
    XCTAssertEqual(partial, try javaDeclaredNatives(forTypeNamed: "PartlyMarshalled"))

    let frozen = try macroRegisteredNatives(forTypeNamed: "Frozen")
    XCTAssertFalse(frozen.contains("retitleImpl"),
                   "a `let` property leaves the peer with no setter to write through")
    XCTAssertEqual(frozen, try javaDeclaredNatives(forTypeNamed: "Frozen"))
  }

  /// A static has no receiver to have been marshalled, so it keeps its native
  /// on both sides. This is the half that would be easy to drop by accident.
  func testStaticsKeepTheirNatives() throws {
    let registered = try macroRegisteredNatives(forTypeNamed: "Row")

    XCTAssertTrue(registered.contains("getSchemaVersionImpl"))
    XCTAssertTrue(registered.contains("setSchemaVersionImpl"))
    XCTAssertTrue(registered.contains("describeImpl"))
  }
}
