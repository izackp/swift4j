// Bridges Foundation.Data to Java byte[].
//
// Java byte = signed Int8. Swift Data is a collection of UInt8.
// JNI byte[] uses jbyte (Int8). Wire format is identical bit-for-bit;
// the signed/unsigned reinterpretation is a no-op cast.

import Foundation
import CJNI


extension Data: JObjectConvertible, JNullInitializable, JParameterConvertible {

  // JNI signature for byte[]
  public static var javaSignature: String { "[B" }

  public static var javaName: String { "[B" }

  public static var javaClass: JClass {
    return findJavaClass(fqn: "[B")!
  }

  public func toJavaObject() -> JavaObject? {
    let count = self.count
    guard let arr = jni.NewByteArray(count) else { return nil }
    let signed: [Int8] = self.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int8] in
      guard let base = raw.baseAddress else { return [] }
      return base.withMemoryRebound(to: Int8.self, capacity: count) { ptr in
        return Array(UnsafeBufferPointer(start: ptr, count: count))
      }
    }
    jni.SetArrayRegion(arr, 0, count, signed)
    return arr
  }

  public static func fromJavaObject(_ obj: JavaObject) -> Data {
    let count = Int(jni.GetArrayLength(obj))
    var bytes = [Int8](repeating: 0, count: count)
    bytes.withUnsafeMutableBufferPointer { buf in
      if let base = buf.baseAddress {
        jni.GetByteArrayRegion(obj, 0, count, base)
      }
    }
    return bytes.withUnsafeBufferPointer { buf -> Data in
      guard let base = buf.baseAddress else { return Data() }
      return base.withMemoryRebound(to: UInt8.self, capacity: count) { ptr in
        return Data(bytes: ptr, count: count)
      }
    }
  }
}
