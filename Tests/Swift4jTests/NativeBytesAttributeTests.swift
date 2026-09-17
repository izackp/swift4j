import XCTest
import SwiftSyntax
import SwiftParser
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion

@testable import Swift4jMacros
@testable import SwiftSyntaxExtensions

/// Pins `@jvm(nativeBytes:)`: what the class-init writes into the peer's
/// `__nativeBytes` field, and which declarations are refused outright.
///
/// The field is what the collector sees. Left at zero it falls back to
/// `SwiftPtr`'s nominal default, so a type whose real footprint is large looks
/// cheap and nothing ever runs that would free it — the failure mode is an
/// abort under memory pressure, arbitrarily far from the type that caused it.
final class NativeBytesAttributeTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  @jvm
  public struct Inline {
    public var a: Int
    public var b: Int
    public init(a: Int, b: Int) { self.a = a; self.b = b }
  }

  @jvm(nativeBytes: 262144)
  public struct Declared {
    public var text: String
    public init(text: String) { self.text = text }
  }

  @jvm
  public class PlainClass {
    public var count: Int
    public init(count: Int) { self.count = count }
  }

  @jvm(nativeBytes: 4096)
  public class SizedClass {
    public var count: Int
    public init(count: Int) { self.count = count }
  }

  @jvm(serialized: true)
  public struct Copied {
    public var a: Int
    public init(a: Int) { self.a = a }
  }
  """

  // MARK: - reading the attribute

  func testDeclaredValueIsRead() throws {
    XCTAssertEqual(try decl("Declared").declaredNativeBytes, 262_144)
    XCTAssertEqual(try decl("SizedClass").declaredNativeBytes, 4096)
  }

  func testUnstatedIsNil() throws {
    XCTAssertNil(try decl("Inline").declaredNativeBytes)
    XCTAssertNil(try decl("PlainClass").declaredNativeBytes)
  }

  /// Same regression `SerializedAttributeTests` guards: an argument list must
  /// not hide the attribute, or every annotated type stops generating.
  func testArgumentDoesNotBreakExportDiscovery() throws {
    for name in ["Inline", "Declared", "PlainClass", "SizedClass", "Copied"] {
      XCTAssertTrue(try decl(name).isExported, "\(name) must still be discovered as exported")
    }
  }

  // MARK: - what class-init writes

  func testDeclaredValueIsWrittenVerbatim() throws {
    let source = try registerNatives(for: "Declared")
    XCTAssertTrue(source.contains("__nativeBytes"),
                  "a declared footprint must reach the peer's field")
    XCTAssertTrue(source.contains("JavaLong(262144)"),
                  "the declared count must be written, not the stride: a String's "
                  + "heap is not inline, so the stride would under-report it")
    XCTAssertFalse(source.contains("MemoryLayout<Declared>.stride"),
                   "the declaration overrides the computed number")
  }

  /// The pre-existing behaviour, unchanged: an unannotated value type still
  /// reports its stride.
  func testUnannotatedValueTypeStillReportsStride() throws {
    let source = try registerNatives(for: "Inline")
    XCTAssertTrue(source.contains("JavaLong(MemoryLayout<Inline>.stride)"))
  }

  /// The gap this argument closes. A class handle boxes a reference, so there
  /// is no number to compute and nothing was written at all.
  func testClassWritesNothingUnlessDeclared() throws {
    XCTAssertFalse(try registerNatives(for: "PlainClass").contains("__nativeBytes"),
                   "a class has no computable footprint, so nothing is written")
    XCTAssertTrue(try registerNatives(for: "SizedClass").contains("JavaLong(4096)"),
                  "a declared footprint is the only way a class reports one")
  }

  func testSerializedTypeWritesNothing() throws {
    XCTAssertFalse(try registerNatives(for: "Copied").contains("__nativeBytes"),
                   "a serialized peer holds no native memory to account for")
  }

  // MARK: - refusals

  func testSerializedWithNativeBytesIsRefused() {
    assertRefused("""
    @jvm(serialized: true, nativeBytes: 1024)
    public struct Bad { public var a: Int }
    """)
  }

  func testEnumWithNativeBytesIsRefused() {
    assertRefused("""
    @jvm(nativeBytes: 1024)
    public enum Bad { case one }
    """)
  }

  func testNonLiteralIsRefused() {
    assertRefused("""
    @jvm(nativeBytes: 32 * 1024)
    public struct Bad { public var a: Int }
    """)
  }

  func testZeroIsRefused() {
    assertRefused("""
    @jvm(nativeBytes: 0)
    public struct Bad { public var a: Int }
    """)
  }

  func testUnderscoreSeparatedLiteralIsAccepted() throws {
    let parsed = Parser.parse(source: """
    @jvm(nativeBytes: 262_144)
    public struct Grouped { public var a: Int }
    """)
    let decl = try XCTUnwrap(parsed.statements.first?.item.as(StructDeclSyntax.self))
    XCTAssertEqual(decl.declaredNativeBytes, 262_144)
    XCTAssertNoThrow(try JvmMacro.assertNativeBytesIsApplicable(decl))
  }

  // MARK: - harness

  private func decls(_ fixture: String = NativeBytesAttributeTests.fixture) -> [String: any TypeDeclSyntax] {
    var found: [String: any TypeDeclSyntax] = [:]
    for stmt in Parser.parse(source: fixture).statements {
      if let d = stmt.item.as(StructDeclSyntax.self) { found[d.typeName] = d }
      else if let d = stmt.item.as(ClassDeclSyntax.self) { found[d.typeName] = d }
      else if let d = stmt.item.as(EnumDeclSyntax.self) { found[d.typeName] = d }
    }
    return found
  }

  private func decl(_ name: String) throws -> any TypeDeclSyntax {
    try XCTUnwrap(decls()[name])
  }

  private func registerNatives(for name: String) throws -> String {
    let decl = try XCTUnwrap(decls()[name] as? (any JvmTypeDeclSyntax))
    let context = BasicMacroExpansionContext()
    return try decl.expandRegisterNatives(in: context, parents: [], namespacePath: [])
  }

  private func assertRefused(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
    let parsed = Parser.parse(source: source)
    guard let item = parsed.statements.first?.item else {
      return XCTFail("fixture parsed to nothing", file: file, line: line)
    }
    let group: (any DeclGroupSyntax)? = item.as(StructDeclSyntax.self)
      ?? (item.as(ClassDeclSyntax.self) as (any DeclGroupSyntax)?)
      ?? (item.as(EnumDeclSyntax.self) as (any DeclGroupSyntax)?)
    guard let group else {
      return XCTFail("fixture is not a type declaration", file: file, line: line)
    }
    XCTAssertThrowsError(try JvmMacro.assertNativeBytesIsApplicable(group),
                         "the declaration must be refused rather than silently ignored",
                         file: file, line: line)
  }
}
