import XCTest
import Foundation

@testable import swift4j_cli

/// Pins `--value-type`, which declares that a Swift type crosses as a Java
/// value rather than a pointer-backed peer — generalising the built-in
/// `Date` -> `java.util.Date` and `Data` -> `byte[]` mappings to types swift4j
/// ships no knowledge of.
///
/// The type under test is named `LcUUID` because that is the case that
/// motivated the flag: a 16-byte `uuid_t` whose only exported member is a
/// computed `uuidString`, so a pointer-backed peer costs a handle per UUID and
/// a serialized peer costs a 36-character string per marshal, while
/// `java.util.UUID` carries the same 16 bytes as two longs.
///
/// As with `Date`, the interesting assertions are the negative ones. The macro
/// registers an `unsafeWith` native for any non-primitive property name,
/// because it cannot resolve what a name refers to. The CLI must therefore
/// declare that native — or RegisterNatives unbinds every native on the class —
/// while exposing no public scope, since a value-bridged property has no
/// interior pointer to borrow.
final class ValueTypeMappingTests: XCTestCase {

  /// `LcUUID` is deliberately *not* declared `@jvm` here: the whole point is a
  /// type the registry has never seen, reached only through the flag.
  private static let fixture = """
  import Swift4j

  @jvm
  public struct Row {
    public var id: LcUUID
    public var parentId: LcUUID?
    public var label: String
    public init(id: LcUUID, parentId: LcUUID?, label: String) {
      self.id = id
      self.parentId = parentId
      self.label = label
    }
  }
  """

  private func generate(valueTypes: [String: String]) throws -> String {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-value-type-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    let generator = ProxyGenerator(package: "test.pkg",
                                   javaVersion: 11,
                                   valueTypes: valueTypes)
    for result in try generator.run(paths: [file.path]) where result.source.contains("class Row ") {
      return result.source
    }
    XCTFail("generator produced no peer for Row")
    return ""
  }

  /// Runs of whitespace collapse to one space before matching, so an assertion
  /// pins the declaration's structure rather than the double space an empty
  /// modifier interpolation happens to leave behind.
  private func generateNormalized(valueTypes: [String: String]) throws -> String {
    try generate(valueTypes: valueTypes)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
  }

  func testMappedTypeIsNamedAndImportedAsTheJavaValue() throws {
    let row = try generateNormalized(valueTypes: ["LcUUID": "java.util.UUID"])

    XCTAssertTrue(row.contains("public UUID getId()"),
                  "a value-bridged property should be typed as the Java value")
    XCTAssertTrue(row.contains("import java.util.UUID;"),
                  "the qualified name must be imported, or the short name "
                  + "resolves to the generated package and fails to load")
    XCTAssertFalse(row.contains("LcUUID"),
                   "no trace of the Swift name should survive in the peer")
  }

  func testOptionalOfAMappedTypeIsAlsoBridged() throws {
    let row = try generateNormalized(valueTypes: ["LcUUID": "java.util.UUID"])

    XCTAssertTrue(row.contains("public @Nullable UUID getParentId()"),
                  "an optional of a value-bridged type bridges the payload")
  }

  /// Without the flag the same fixture emits the bare Swift name — which is
  /// what makes this a real mapping rather than a coincidence of the fixture.
  func testUnmappedTypeStillEmitsTheBareSwiftName() throws {
    let row = try generateNormalized(valueTypes: [:])

    XCTAssertTrue(row.contains("public LcUUID getId()"),
                  "an unmapped, unregistered type falls through to its bare name")
    XCTAssertFalse(row.contains("import java.util.UUID;"))
  }

  /// The flag is consulted only from `default:`, so shadowing a built-in is a
  /// no-op rather than a way to break every generated signature at once.
  func testBuiltInMappingsCannotBeOverridden() throws {
    let row = try generateNormalized(valueTypes: ["String": "com.example.NotAString"])

    XCTAssertTrue(row.contains("public String getLabel()"),
                  "String is a built-in mapping and must win over --value-type")
    XCTAssertFalse(row.contains("com.example.NotAString"))
    XCTAssertFalse(row.contains("import com.example.NotAString;"))
  }

  /// The `Date` trap, for a mapped name. The macro registers the native from
  /// syntax alone; the CLI declares it from the same syntax and suppresses the
  /// public wrapper because the registry cannot resolve the name to a @jvm
  /// struct. Both halves have to stay in agreement.
  func testMappedTypeDeclaresTheBorrowNativeButExposesNoScope() throws {
    let row = try generateNormalized(valueTypes: ["LcUUID": "java.util.UUID"])

    XCTAssertTrue(row.contains("private native void unsafeWithIdImpl(long ptr,"),
                  "the macro registers this native, so the Java method must "
                  + "exist or RegisterNatives unbinds every native on the class")
    XCTAssertFalse(row.contains("public void unsafeWithId("),
                   "a value-bridged property has no interior pointer to borrow")
  }
}
