import XCTest
import Foundation

@testable import swift4j_cli

/// Two `@jvm` types can share an unqualified name — one top-level, one under a
/// namespace. CaptureAPI has exactly this: a GRDB row `Subject` and a network
/// DTO `Server.Subject`.
///
/// Extensions must attach by *qualified* path. Matching on the bare name gives
/// the namespaced type the other one's members, and for a serialized type that
/// is not cosmetic: an extra member changes the generated constructor, so the
/// descriptor the macro computes from the Swift declaration no longer matches
/// what the CLI emitted. `getMethodID` then returns nil and `class_init` traps
/// — at runtime, on first use, from a build that was green.
///
/// The namespace is what makes this easy to get wrong. `Server.Subject` is
/// declared inside `extension Server`, which is a namespace rather than a
/// parent type, so the declaration's `parents` list is empty and it looks
/// top-level to a parents-only check.
final class CoNamedTypeExtensionTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  public enum Wire { }

  @jvm(serialized: true)
  public struct Record {
    public var id: Int
    public init(id: Int) { self.id = id }
  }

  public extension Record {
    public var localOnly: Int { id * 2 }
  }

  public extension Wire {
    @jvm(serialized: true)
    struct Record {
      public var id: Int
      public init(id: Int) { self.id = id }
    }
  }

  public extension Wire.Record {
    public var wireOnly: String { "\\(id)" }
  }
  """

  /// Keyed by the generated file's path suffix, because both types produce a
  /// class named `Record` and only the directory distinguishes them.
  private func generate() throws -> (topLevel: String, namespaced: String) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-conamed-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    let generator = ProxyGenerator(package: "test.pkg", javaVersion: 11)
    var topLevel: String?
    var namespaced: String?
    for result in try generator.run(paths: [file.path]) {
      guard result.source.contains("class Record ") else { continue }
      if result.filename.contains("Wire") {
        namespaced = result.source
      } else {
        topLevel = result.source
      }
    }
    return (try XCTUnwrap(topLevel), try XCTUnwrap(namespaced))
  }

  func testNamespacedTypeDoesNotAbsorbTheBareTypesExtension() throws {
    let (_, namespaced) = try generate()

    XCTAssertFalse(namespaced.contains("localOnly"),
                   "Wire.Record must not pick up `extension Record`")
    XCTAssertTrue(namespaced.contains("wireOnly"),
                  "its own qualified extension still attaches")
  }

  func testBareTypeDoesNotAbsorbTheNamespacedTypesExtension() throws {
    let (topLevel, _) = try generate()

    XCTAssertTrue(topLevel.contains("localOnly"))
    XCTAssertFalse(topLevel.contains("wireOnly"),
                   "`extension Wire.Record` belongs to the namespaced type")
  }

  /// The constructor is where a leaked member does damage, because the macro
  /// builds the descriptor from the Swift declaration and the CLI builds the
  /// constructor from its own member list. They have to agree exactly.
  func testConstructorArityMatchesEachTypesOwnMembers() throws {
    let (topLevel, namespaced) = try generate()

    XCTAssertTrue(topLevel.contains("public Record(long id, long localOnly)"),
                  "the bare type carries its own extension member")
    XCTAssertTrue(namespaced.contains("public Record(long id, String wireOnly)"),
                  "the namespaced type carries only its own")
  }
}
