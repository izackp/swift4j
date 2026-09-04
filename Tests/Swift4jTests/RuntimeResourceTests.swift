import XCTest
import Foundation

/// `Package.swift` lists the runtime Java files one by one, so adding a file to
/// `Sources/Swift4j/java` without adding it there ships peers that reference a
/// class no consumer has.
///
/// That is not hypothetical: `SwiftCacheOwner` was added, the generated peers
/// began implementing it, and the Android build failed with "Cannot access
/// 'SwiftCacheOwner' which is a supertype of 'FullSubject'". swift4j itself
/// built and tested green throughout, because nothing here consumes the
/// resource bundle.
final class RuntimeResourceTests: XCTestCase {

  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Swift4jTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }

  func testEveryRuntimeJavaFileIsDeclaredAsAResource() throws {
    let javaDir = repoRoot
      .appendingPathComponent("Sources/Swift4j/java/io/scade/swift4j")

    let onDisk = try FileManager.default
      .contentsOfDirectory(atPath: javaDir.path)
      .filter { $0.hasSuffix(".java") }
      .sorted()

    XCTAssertFalse(onDisk.isEmpty, "found no runtime Java files; the path is wrong")

    let manifest = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"),
                              encoding: .utf8)

    let missing = onDisk.filter { name in
      !manifest.contains("java/io/scade/swift4j/\(name)")
    }

    XCTAssertTrue(missing.isEmpty,
                  "not declared in Package.swift: \(missing.joined(separator: ", ")). "
                  + "Generated peers that reference these compile here but fail in a "
                  + "consuming Android build, which is where the class is actually needed.")
  }
}
