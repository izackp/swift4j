
extension Error {
  public func toJavaObject() -> JavaObject? {
    // Typed `@jvm` Error: the codegen emits the Java class as
    // `extends Exception`, so JNI can throw it directly and Kotlin can
    // `catch (e: MyError)`. Route through the type's own bridging so the
    // pointer + class identity round-trips intact.
    if let bridged = self as? any JConvertible {
      return bridged.toJavaObject()
    }
    // Generic fallback for non-`@jvm` Swift errors.
    guard let cls = JClass(fqn: "io/scade/swift4j/SwiftError") else {
      fatalError("Cannot find SwiftError class")
    }
    return cls.create("\(type(of: self)): \(self.localizedDescription)")
  }

  public func throwAsJavaException() {
    guard let jobj = toJavaObject() else {
      fatalError("Cannot instantiate SwiftError exception")
    }

    guard jni.Throw(jobj) else {
      fatalError("Throwing an exception failed")
    }
  }
}
