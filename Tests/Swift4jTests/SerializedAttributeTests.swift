import XCTest
import SwiftSyntax
import SwiftParser

@testable import SwiftSyntaxExtensions

/// Pins how `@jvm(serialized:)` is read off a declaration.
///
/// Two things have to hold at once and they pull in opposite directions. The
/// flag must be readable, and adding arguments must not disturb *discovery* —
/// `TypeDeclSyntax.isExported` is defined as `!exportAttributes.isEmpty`, so if
/// an argument list made `findAttributes("jvm")` miss, every annotated type in
/// the codebase would silently stop generating.
final class SerializedAttributeTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  @jvm
  public struct Bare {}

  @jvm(serialized: true)
  public struct Serialized {}

  @jvm(serialized: false)
  public struct ExplicitlyNot {}

  @jvm
  public class RefType {}

  public struct NotExported {}
  """

  private func types() -> [String: any TypeDeclSyntax] {
    let source = Parser.parse(source: Self.fixture)
    var found: [String: any TypeDeclSyntax] = [:]
    for stmt in source.statements {
      if let decl = stmt.item.as(StructDeclSyntax.self) {
        found[decl.typeName] = decl
      } else if let decl = stmt.item.as(ClassDeclSyntax.self) {
        found[decl.typeName] = decl
      }
    }
    return found
  }

  func testBareJvmIsNotSerialized() throws {
    let decl = try XCTUnwrap(types()["Bare"])
    XCTAssertFalse(decl.isSerialized,
                   "@jvm with no arguments must keep the existing handle behaviour")
  }

  func testSerializedTrueIsRead() throws {
    let decl = try XCTUnwrap(types()["Serialized"])
    XCTAssertTrue(decl.isSerialized)
  }

  func testSerializedFalseIsRead() throws {
    let decl = try XCTUnwrap(types()["ExplicitlyNot"])
    XCTAssertFalse(decl.isSerialized)
  }

  /// The regression that would be catastrophic and silent: an argument list
  /// must not hide the attribute from discovery.
  func testArgumentsDoNotBreakExportDiscovery() throws {
    let all = types()
    for name in ["Bare", "Serialized", "ExplicitlyNot", "RefType"] {
      let decl = try XCTUnwrap(all[name])
      XCTAssertTrue(decl.isExported, "\(name) must still be discovered as exported")
    }
    let plain = try XCTUnwrap(all["NotExported"])
    XCTAssertFalse(plain.isExported, "a type with no @jvm is still not exported")
  }
}
