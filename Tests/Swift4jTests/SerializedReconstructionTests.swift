import XCTest
import SwiftSyntax
import SwiftParser
import SwiftSyntaxExtensions

@testable import Swift4jMacros

/// Whether a Java value of a serialized type carries enough to rebuild the
/// Swift one.
///
/// This decides between generating a reconstruction and generating nothing, and
/// getting it wrong in the permissive direction is the dangerous case: a type
/// whose storage is not fully marshalled would rebuild with default values —
/// for `LcUUID`, a zero UUID, which is a valid-looking identifier for the wrong
/// row rather than an obvious failure.
///
/// The negative cases cannot be fixtures in `Swift4jFixtures`, because failing
/// to compile is exactly the intended behaviour there.
final class SerializedReconstructionTests: XCTestCase {

  private static let fixture = """
  import Swift4j

  @jvm(serialized: true)
  public struct FullyMarshalled {
    public var id: Int
    public var name: String?
    public var derived: Bool { id > 0 }
    public static var version: Int = 1
  }

  @jvm(serialized: true)
  public struct HasHiddenStorage {
    @nonjvm public var secret: Int
    public var id: Int
  }

  /// The LcUUID shape: every marshalled member is computed, and the only
  /// storage is opted out. Reconstruction would silently produce a default.
  @jvm(serialized: true)
  public struct ComputedFacadeOverHiddenStorage {
    @nonjvm public private(set) var raw: Int = 0
    public var text: String { "\\(raw)" }
  }

  /// A `let` is storage too, and a marshalled one is assignable in an init.
  @jvm(serialized: true)
  public struct ImmutableStorage {
    public let id: Int
  }
  """

  private func structs() -> [String: StructDeclSyntax] {
    let source = Parser.parse(source: Self.fixture)
    var found: [String: StructDeclSyntax] = [:]
    for stmt in source.statements {
      if let decl = stmt.item.as(StructDeclSyntax.self) {
        found[decl.typeName] = decl
      }
    }
    return found
  }

  func testFullyMarshalledTypeIsReconstructible() throws {
    let decl = try XCTUnwrap(structs()["FullyMarshalled"])
    XCTAssertTrue(decl.isSerializedReconstructible)
  }

  func testHiddenStoredPropertyBlocksReconstruction() throws {
    let decl = try XCTUnwrap(structs()["HasHiddenStorage"])
    XCTAssertFalse(decl.isSerializedReconstructible,
                   "@nonjvm storage cannot be recovered from the Java value")
  }

  func testComputedFacadeOverHiddenStorageBlocksReconstruction() throws {
    let decl = try XCTUnwrap(structs()["ComputedFacadeOverHiddenStorage"])
    XCTAssertFalse(decl.isSerializedReconstructible,
                   "a marshalled computed property does not make the storage "
                   + "behind it recoverable")
  }

  func testImmutableStorageIsReconstructible() throws {
    let decl = try XCTUnwrap(structs()["ImmutableStorage"])
    XCTAssertTrue(decl.isSerializedReconstructible,
                  "a let is assignable once, in an init")
  }

  /// Computed properties are marshalled outbound and skipped inbound: there is
  /// nothing to assign, and assigning one would not compile.
  func testComputedAndStaticPropertiesAreNotAssigned() throws {
    let decl = try XCTUnwrap(structs()["FullyMarshalled"])
    let assigned = decl.serializedStoredProperties.map { $0.name }

    XCTAssertEqual(assigned, ["id", "name"])
    XCTAssertFalse(assigned.contains("derived"))
    XCTAssertFalse(assigned.contains("version"))
  }

  /// A hand-written conversion is a bridge witness, not API. Bridging one
  /// yields a Java method taking `JavaObject` — which has no Java mapping — and
  /// registers a native nothing provides. Normally these are macro-generated
  /// and never seen by the generators; they only appear once an author writes
  /// one, which the non-reconstructible case requires.
  func testBridgeWitnessesAreNotBridgedAsApi() {
    let source = Parser.parse(source: """
    extension Opaque {
      public static func fromJavaObject(_ obj: JavaObject?) -> Opaque { fatalError() }
      public func toJavaObject() -> JavaObject? { nil }
      public static func fromUnownedPointer(_ raw: UnsafeMutableRawPointer) -> JavaObject? { nil }
      public func toJavaParameter() -> JavaParameter { fatalError() }
      public func realApi() -> Int { 0 }
    }
    """)

    var verdicts: [String: Bool] = [:]
    for stmt in source.statements {
      guard let ext = stmt.item.as(ExtensionDeclSyntax.self) else { continue }
      for member in ext.memberBlock.members {
        guard let fn = member.decl.as(FunctionDeclSyntax.self) else { continue }
        verdicts[fn.name.text] = fn.isBridgeable(typeConformsToHashable: false)
      }
    }

    XCTAssertEqual(verdicts["fromJavaObject"], false)
    XCTAssertEqual(verdicts["toJavaObject"], false)
    XCTAssertEqual(verdicts["fromUnownedPointer"], false)
    XCTAssertEqual(verdicts["toJavaParameter"], false)
    XCTAssertEqual(verdicts["realApi"], true,
                   "an ordinary method in the same extension is still bridged")
  }

  /// Outbound carries the computed property; inbound does not. The asymmetry is
  /// deliberate and worth pinning, since the constructor descriptor is built
  /// from the outbound list and a reconstruction from the inbound one.
  func testOutboundCarriesMoreThanInbound() throws {
    let decl = try XCTUnwrap(structs()["FullyMarshalled"])

    XCTAssertEqual(decl.serializedProperties.map { $0.name }, ["id", "name", "derived"])
    XCTAssertEqual(decl.serializedStoredProperties.map { $0.name }, ["id", "name"])
  }
}
