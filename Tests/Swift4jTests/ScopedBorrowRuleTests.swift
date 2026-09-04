import XCTest
import SwiftSyntax
import SwiftParser
import SwiftSyntaxExtensions

@testable import Swift4jMacros
@testable import swift4j_cli

/// The scoped-borrow rule is implemented twice, once per generator, because the
/// macro and swift4j-cli share no code at the call site. They MUST agree: the
/// macro registers `unsafeWith<X>Impl` for its set and the CLI declares the Java
/// native for its set, and `RegisterNatives` fails the *whole batch* if any
/// registered native has no matching method — which unbinds every native on the
/// class and crashes on first use, with a green build.
///
/// So this is not a style check. It is the only thing standing between a
/// one-word edit in either rule and a runtime failure no host build can see.
final class ScopedBorrowRuleTests: XCTestCase {

  /// One property per interesting shape. Names are irrelevant; the type syntax
  /// and the accessor form are what both rules key on.
  private static let fixture = """
  @jvm
  public struct Fixture {
    // Pointer-boxed @jvm types: the real borrow case.
    public var subject: Subject
    public var namespaced: Server.Subject

    // Bridged by conversion, so no interior pointer exists for them.
    public var modifiedAt: Date
    public var link: URL

    // Primitives and the two immutable peers.
    public var count: Int
    public var ratio: Double
    public var flag: Bool
    public var name: String
    public var blob: Data

    // One level of optional is borrowable; the payload has an address.
    public var maybe: Subject?
    public var forced: Subject!
    public var nested: Subject??

    // Arrays get element-wise iteration, not a scope over the array itself.
    public var many: [Subject]
    public var stamps: [Date]
    public var counts: [Int]

    // No single peer to point at, and no element-wise form either.
    public var mapped: [String: Subject]

    // Not addressable, or not a stored location at all.
    public let immutable: Subject
    public static var shared: Subject
    public var computed: Subject { Subject() }
    public var observed: Subject { didSet { } }
  }
  """

  private func fixtureProperties() -> [(decl: VariableDeclSyntax, vars: [VariableDeclSyntax.VarDecl])] {
    let source = Parser.parse(source: Self.fixture)
    let collector = PropertyCollector(viewMode: .fixedUp)
    collector.walk(source)
    return collector.found.map { ($0, $0.decls) }
  }

  /// The invariant. Any drift between the two implementations fails here.
  func testBothGeneratorsSelectTheSameProperties() {
    var checked = 0

    for (decl, vars) in fixtureProperties() {
      for varDecl in vars {
        let fromMacro = VariableDeclSyntax.scopedBorrowable(varDecl, isStatic: decl.isStatic)
        let fromCLI = VarGenerator.scopedBorrowable(varDecl, isStatic: decl.isStatic)

        XCTAssertEqual(fromMacro, fromCLI,
                       "generators disagree on '\(varDecl.name)': macro=\(fromMacro) cli=\(fromCLI). "
                       + "A mismatch unbinds every native on the class at RegisterNatives.")

        let eachMacro = VariableDeclSyntax.scopedForEachable(varDecl, isStatic: decl.isStatic)
        let eachCLI = VarGenerator.scopedForEachable(varDecl, isStatic: decl.isStatic)

        XCTAssertEqual(eachMacro, eachCLI,
                       "generators disagree on forEach for '\(varDecl.name)': "
                       + "macro=\(eachMacro) cli=\(eachCLI). Same consequence.")
        checked += 1
      }
    }

    XCTAssertGreaterThan(checked, 0, "fixture parsed to nothing; the rule was never exercised")
  }

  /// Pins the rule itself, so a change to what is selected is a deliberate edit
  /// rather than an accident. Agreement alone would still pass if both sides
  /// were changed to select nothing.
  func testRuleSelectsExactlyTheAddressableJvmProperties() {
    var selected: Set<String> = []

    for (decl, vars) in fixtureProperties() {
      for varDecl in vars where VariableDeclSyntax.scopedBorrowable(varDecl, isStatic: decl.isStatic) {
        selected.insert(varDecl.name)
      }
    }

    // `modifiedAt` and `link` are in the set on purpose. The rule is
    // deliberately over-broad because the macro cannot resolve what a type name
    // refers to; the CLI declares their native but exposes no public wrapper,
    // and Swift resolves them onto the convert/write-back overload.
    //
    // `observed` is in the set on purpose too, and this is the one case that
    // differs from the interior-pointer design that preceded this. That one
    // wrote directly into the parent's storage, so willSet/didSet never ran and
    // it had to reject observed properties outright. A scoped borrow is an
    // inout access, which for an observed stored property goes through the
    // synthesized modify accessor — store back, then run didSet. So observers
    // fire and the property does not need excluding.
    // `maybe` is an `Optional`. Force-unwrap is an lvalue, so `&value!`
    // addresses the payload where it lies — verified in Swift: writes reach the
    // original, the address is stable, and it falls inside the owner's storage.
    // One level only; `T??` has no single sensible borrow.
    // `forced` (`Subject!`) is NOT selected. It parses as
    // ImplicitlyUnwrappedOptionalTypeSyntax rather than OptionalTypeSyntax, so
    // the optional branch never sees it. Same layout as `Subject?` and it could
    // be borrowed identically — but both generators exclude it, so this is a
    // missing feature rather than a mismatch, and R2 is not at risk.
    XCTAssertEqual(selected, ["subject", "namespaced", "modifiedAt", "link", "observed", "maybe"])
  }

  /// The forEach half of the rule, pinned the same way.
  func testForEachRuleSelectsExactlyTheArrayProperties() {
    var selected: Set<String> = []

    for (decl, vars) in fixtureProperties() {
      for varDecl in vars where VariableDeclSyntax.scopedForEachable(varDecl, isStatic: decl.isStatic) {
        selected.insert(varDecl.name)
      }
    }

    // `stamps` is over-broad on purpose, exactly as `modifiedAt` is above: the
    // macro cannot tell that `Date` bridges by conversion, so it registers the
    // native and the CLI declares it without exposing a wrapper.
    //
    // `counts` is out because `Int` is primitive, and `mapped` because a
    // dictionary's values have no stable address to hand out.
    XCTAssertEqual(selected, ["many", "stamps"])
  }

  /// Guards the half of the rule that is genuinely duplicated data rather than
  /// duplicated logic.
  func testNonBorrowableNamesCoversEveryPrimitive() {
    let primitives = ["Void", "Bool", "Int", "Int64", "Int32", "Int16", "Int8",
                      "UInt", "UInt64", "UInt32", "UInt16", "UInt8",
                      "Float", "Double"]

    for name in primitives {
      XCTAssertTrue(VarGenerator.nonBorrowableNames.contains(name),
                    "'\(name)' is primitive in the macro but missing from the CLI's list")
    }
    XCTAssertTrue(VarGenerator.nonBorrowableNames.contains("String"))
    XCTAssertTrue(VarGenerator.nonBorrowableNames.contains("Data"))
  }
}


private final class PropertyCollector: SyntaxVisitor {
  var found: [VariableDeclSyntax] = []

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    found.append(node)
    return .skipChildren
  }
}
