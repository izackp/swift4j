import XCTest
import Foundation
import SwiftSyntax
import SwiftParser
import SwiftSyntaxExtensions

@testable import Swift4jMacros
@testable import swift4j_cli

/// Every native the macro registers must exist as a method on the generated
/// peer. `RegisterNatives` is all-or-nothing: one missing method unbinds every
/// native on that type, and the failure appears at class-init in the consuming
/// app, not at build time.
///
/// The existing rule test compares the two generators' *property* rules. This
/// compares the whole registered set, per type kind, which is where the last
/// mismatch came from: `copyImpl` was registered for any value type — enums
/// included — while only structs got a `copy()` in the peer. Every payload enum
/// was fully unbound and nothing caught it until a JVM ran one.
final class NativeRegistrationTests: XCTestCase {

  private static let fixture = """
  import Foundation
  import Swift4j

  @jvm
  public struct AStruct {
    public var name: String
    public var inner: AnotherStruct
    public init(name: String, inner: AnotherStruct) {
      self.name = name
      self.inner = inner
    }
    public func describe() -> String { name }
  }

  @jvm
  public struct AnotherStruct {
    public var value: Int
    public init(value: Int) { self.value = value }
  }

  @jvm
  public class AClass {
    public var count: Int
    public init(count: Int) { self.count = count }
  }

  @jvm
  public enum SimpleEnum {
    case one
    case two
  }

  @jvm
  public enum PayloadEnum {
    case withInt(value: Int)
    case withText(text: String)
  }
  """

  /// The invariant, per type kind.
  func testEveryRegisteredNativeExistsOnThePeer() throws {
    let (registered, declared) = try generate()

    XCTAssertFalse(registered.isEmpty, "fixture registered nothing; the test proves nothing")
    XCTAssertTrue(registered.values.contains { !$0.isEmpty },
                  "no type registered any native; the comparison is vacuous")

    for (type, names) in registered.sorted(by: { $0.key < $1.key }) {
      // A simple enum is bridged by ordinal, so it legitimately registers and
      // declares nothing. Only assert a peer exists where natives are involved.
      guard let peer = declared[type] else {
        XCTFail("no peer generated for '\(type)'")
        continue
      }

      let missing = names.subtracting(peer)
      XCTAssertTrue(missing.isEmpty,
                    "'\(type)' registers native(s) its peer does not declare: "
                    + "\(missing.sorted().joined(separator: ", ")). "
                    + "RegisterNatives fails the whole batch, so every native on "
                    + "'\(type)' would be unbound at class-init.")
    }
  }

  /// Pins the specific regression: copyImpl belongs to structs and nothing else.
  func testCopyImplIsRegisteredForStructsOnly() throws {
    let (registered, _) = try generate()

    XCTAssertTrue(registered["AStruct"]?.contains("copyImpl") ?? false,
                  "a struct should register copyImpl")
    XCTAssertFalse(registered["AClass"]?.contains("copyImpl") ?? true,
                   "a class has no copy(); registering copyImpl would unbind the class")
    XCTAssertFalse(registered["PayloadEnum"]?.contains("copyImpl") ?? true,
                   "a payload enum's Kotlin peer declares no copyImpl")
    XCTAssertFalse(registered["SimpleEnum"]?.contains("copyImpl") ?? true,
                   "a simple enum is bridged by ordinal and is not pointer-backed")
  }

  // MARK: - harness

  /// Returns (natives the macro registers, natives the peer declares), keyed by
  /// type name.
  private func generate() throws -> ([String: Set<String>], [String: Set<String>]) {
    let source = Parser.parse(source: Self.fixture)

    let collector = TypeCollector(viewMode: .fixedUp)
    collector.walk(source)

    var registered: [String: Set<String>] = [:]
    for decl in collector.found {
      let natives = try decl.expandCreateNativeMethods(parents: [], namespacePath: [])
      registered[decl.typeName] = Set(natives.compactMap(Self.registeredName))
    }

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift4j-natives-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("Fixture.swift")
    try Self.fixture.write(to: file, atomically: true, encoding: .utf8)

    var declared: [String: Set<String>] = [:]
    let generator = ProxyGenerator(package: "test.pkg", javaVersion: 11)
    for result in try generator.run(paths: [file.path]) {
      for name in registered.keys where Self.declares(result.source, type: name) {
        declared[name] = Self.declaredNatives(in: result.source)
      }
    }
    return (registered, declared)
  }

  /// `JNINativeMethod2(name: "copyImpl", sig: ...)` -> `copyImpl`.
  private static func registeredName(_ entry: String) -> String? {
    guard let start = entry.range(of: "name: \"") else { return nil }
    let rest = entry[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
  }

  private static func declares(_ source: String, type: String) -> Bool {
    return source.contains("class \(type) ")
        || source.contains("class \(type)(")
        || source.contains("class \(type):")
        || source.contains("enum \(type) ")
  }

  /// Java `native <ret> name(` and Kotlin `external fun name(`.
  private static func declaredNatives(in source: String) -> Set<String> {
    var found: Set<String> = []
    for line in source.split(separator: "\n") {
      let text = String(line)
      if let r = text.range(of: "external fun ") {
        found.formUnion(Self.identifier(after: r.upperBound, in: text))
      } else if text.contains(" native ") {
        // The name is the token immediately before the parameter list.
        guard let paren = text.firstIndex(of: "(") else { continue }
        let head = text[..<paren]
        if let last = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).last {
          found.insert(String(last))
        }
      }
    }
    return found
  }

  private static func identifier(after index: String.Index, in text: String) -> Set<String> {
    let rest = text[index...]
    let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    return name.isEmpty ? [] : [String(name)]
  }
}


private final class TypeCollector: SyntaxVisitor {
  var found: [any JvmTypeDeclSyntax] = []

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported { found.append(node) }
    return .skipChildren
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported { found.append(node) }
    return .skipChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported { found.append(node) }
    return .skipChildren
  }
}
