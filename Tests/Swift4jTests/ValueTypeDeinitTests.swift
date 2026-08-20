import XCTest

private final class Probe {
  static var liveCount = 0
  init() { Probe.liveCount += 1 }
  deinit { Probe.liveCount -= 1 }
}

private struct Payload {
  let probe: Probe
  let name: String
}

/// The bridging macros box a value type with `allocate` + `initialize(to:)` and
/// free it from `deinit_jni`. `initialize(to:)` retains every refcounted field of
/// the copy, so the free path has to `deinitialize` before it `deallocate`s or
/// those fields are leaked for the lifetime of the process.
final class ValueTypeDeinitTests: XCTestCase {

  private func makeBox() -> Int {
    let p = UnsafeMutablePointer<Payload>.allocate(capacity: 1)
    p.initialize(to: Payload(probe: Probe(), name: "subject"))
    return Int(bitPattern: p)
  }

  func testDeinitializeReleasesStoredFields() {
    Probe.liveCount = 0
    let raw = makeBox()
    XCTAssertEqual(Probe.liveCount, 1, "box should own the only reference")

    guard let p = UnsafeMutablePointer<Payload>(bitPattern: raw) else {
      return XCTFail("bitPattern round-trip failed")
    }
    p.deinitialize(count: 1)
    p.deallocate()

    XCTAssertEqual(Probe.liveCount, 0, "deinitialize must release the boxed fields")
  }

  func testDeallocateAloneLeaksStoredFields() {
    Probe.liveCount = 0
    let raw = makeBox()

    guard let p = UnsafeMutablePointer<Payload>(bitPattern: raw) else {
      return XCTFail("bitPattern round-trip failed")
    }
    p.deallocate()

    XCTAssertEqual(Probe.liveCount, 1, "documents the leak that deinitialize fixes")
  }

  /// Guards the emitted `deinit_jni` templates against regressing to a bare
  /// `deallocate()`. Both value-type free paths must deinitialize first.
  func testEmittedDeinitTemplatesDeinitializeBeforeDeallocate() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let templates = [
      "Sources/Swift4jMacros/JvmValueTypeDeclSyntax.swift",
      "Sources/Swift4jMacros/JvmBindingMacro.swift",
    ]

    for relativePath in templates {
      let url = root.appendingPathComponent(relativePath)
      let source = try String(contentsOf: url, encoding: .utf8)
      let lines = source.components(separatedBy: .newlines)

      let deallocateLines = lines.indices.filter { lines[$0].contains(".deallocate()") }
      XCTAssertFalse(deallocateLines.isEmpty, "no deallocate() found in \(relativePath)")

      for index in deallocateLines {
        let preceding = lines[..<index].suffix(2).joined(separator: "\n")
        XCTAssertTrue(
          preceding.contains("deinitialize(count: 1)"),
          "\(relativePath):\(index + 1) deallocates without deinitializing first"
        )
      }
    }
  }
}
