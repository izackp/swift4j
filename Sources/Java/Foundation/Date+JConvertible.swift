import Foundation

extension Date: JObjectConvertible, JNullInitializable, JParameterConvertible {
  private enum __JClass__ {
    static let name = "java/util/Date"
    static let shared = {
      guard let cls = JClass(fqn: javaName) else {
        fatalError("Could not find \(javaName) class")
      }
      return cls
    } ()
  }

  public nonisolated static var javaName: String { __JClass__.name }
  public nonisolated static var javaClass: JClass { __JClass__.shared }

  public static func fromJavaObject(_ obj: JavaObject) -> Date {
    let ms: Int64 = JObject(obj).call(method: "getTime")
    return Date(timeIntervalSince1970: Double(ms) / 1000.0)
  }

  public func toJavaObject() -> JavaObject? {
    let ms = Int64((timeIntervalSince1970 * 1000.0).rounded())
    return Date.javaClass.create(ms)
  }
}
