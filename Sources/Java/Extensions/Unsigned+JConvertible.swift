// Bridges Swift unsigned integer types to Java signed primitives via shared
// JNI wire format. Throws java.lang.IllegalArgumentException at the JNI
// boundary on out-of-range values so behavior is well-defined in release
// builds (no debug-only `assert` reliance).

import Foundation


fileprivate let _illegalArgumentExceptionClass: JavaClass = {
  guard let cls = findJavaClass(fqn: "java/lang/IllegalArgumentException") else {
    fatalError("java.lang.IllegalArgumentException not found")
  }
  return cls.ptr
}()


// MARK: - UInt64 / UInt

public extension UInt64 {
  @inline(__always)
  func toJavaLong() -> Int64 {
    if self > UInt64(Int64.max) {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "UInt64 value \(self) exceeds Int64.max bridging to Java long")
      return 0
    }
    return Int64(self)
  }

  @inline(__always)
  static func fromJavaLong(_ v: Int64) -> UInt64 {
    if v < 0 {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "Java long \(v) is negative; UInt64 bridge expects non-negative")
      return 0
    }
    return UInt64(v)
  }
}

public extension UInt {
  @inline(__always)
  func toJavaLong() -> Int64 { return UInt64(self).toJavaLong() }

  @inline(__always)
  static func fromJavaLong(_ v: Int64) -> UInt {
    let wide = UInt64.fromJavaLong(v)
    guard let narrowed = UInt(exactly: wide) else {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "Java long \(v) does not fit in a \(UInt.bitWidth)-bit Swift UInt")
      return 0
    }
    return narrowed
  }
}


// MARK: - Int

public extension Int {
  @inline(__always)
  static func fromJavaLong(_ v: Int64) -> Int {
    guard let narrowed = Int(exactly: v) else {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "Java long \(v) does not fit in a \(Int.bitWidth)-bit Swift Int")
      return 0
    }
    return narrowed
  }
}


// MARK: - UInt32

public extension UInt32 {
  @inline(__always)
  func toJavaInt() -> Int32 {
    if self > UInt32(Int32.max) {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "UInt32 value \(self) exceeds Int32.max bridging to Java int")
      return 0
    }
    return Int32(self)
  }

  @inline(__always)
  static func fromJavaInt(_ v: Int32) -> UInt32 {
    if v < 0 {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "Java int \(v) is negative; UInt32 bridge expects non-negative")
      return 0
    }
    return UInt32(v)
  }
}


// MARK: - UInt16

public extension UInt16 {
  @inline(__always)
  func toJavaShort() -> Int16 {
    if self > UInt16(Int16.max) {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "UInt16 value \(self) exceeds Int16.max bridging to Java short")
      return 0
    }
    return Int16(self)
  }

  @inline(__always)
  static func fromJavaShort(_ v: Int16) -> UInt16 {
    if v < 0 {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "Java short \(v) is negative; UInt16 bridge expects non-negative")
      return 0
    }
    return UInt16(v)
  }
}


// MARK: - UInt8

public extension UInt8 {
  @inline(__always)
  func toJavaByte() -> Int8 {
    if self > UInt8(Int8.max) {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "UInt8 value \(self) exceeds Int8.max bridging to Java byte")
      return 0
    }
    return Int8(self)
  }

  @inline(__always)
  static func fromJavaByte(_ v: Int8) -> UInt8 {
    if v < 0 {
      _ = jni.ThrowNew(_illegalArgumentExceptionClass,
                       "Java byte \(v) is negative; UInt8 bridge expects non-negative")
      return 0
    }
    return UInt8(v)
  }
}
