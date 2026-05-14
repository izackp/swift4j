import Foundation

// Disambiguate from swift4j's `Java/Generated/net/URL.swift` (Object subclass
// wrapping `java.net.URL`). This file conforms Foundation's URL value type.
// No `JNullInitializable`: URL has no zero-arg init and no sensible empty
// value. Nullable use must go through `URL?` (Optional+JConvertible).
extension Foundation.URL: JObjectConvertible {
  private enum __JClass__ {
    static let name = "java/net/URL"
    static let shared: JClass = {
      guard let cls = JClass(fqn: name) else {
        fatalError("Could not find \(name) class")
      }
      return cls
    }()
    static let toExternalForm: JavaMethodID = {
      guard let mid = shared.getMethodID(name: "toExternalForm", sig: "()Ljava/lang/String;") else {
        fatalError("java/net/URL.toExternalForm() not found")
      }
      return mid
    }()
  }

  public nonisolated static var javaName: String { __JClass__.name }
  public nonisolated static var javaClass: JClass { __JClass__.shared }

  public static func fromJavaObject(_ obj: JavaObject?) -> Foundation.URL {
    guard let obj = obj else {
      fatalError("URL.fromJavaObject: received null — use URL? for nullable Java URLs")
    }
    let spec: String = JObject(obj).call(method: __JClass__.toExternalForm, [])
    guard let url = Foundation.URL(string: spec) else {
      fatalError("URL.fromJavaObject: invalid spec \(spec)")
    }
    return url
  }

  public func toJavaObject() -> JavaObject? {
    return Foundation.URL.javaClass.create(self.absoluteString)
  }
}
