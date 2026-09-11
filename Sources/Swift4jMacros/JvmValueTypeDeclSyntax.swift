import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics


protocol JvmValueTypeDeclSyntax: JvmTypeDeclSyntax {
  func expandToJavaObject(in context: some MacroExpansionContext) -> String
}


extension JvmValueTypeDeclSyntax {
  var selfExpr: String {
    "_self(ptr).pointee"
  }
  
  func expandJavaObjectDecls(in context: some MacroExpansionContext) throws -> String {
    return try expandJavaObjectDeclsAsClass(in: context)
  }

  func expandCtorDecls(in context: some MacroExpansionContext) throws -> String {
    return try expandCtorDeclsAsClass(in: context)
  }

  func expandInitCall(params: String, throwing: Bool, failable: Bool, initName: String) -> String {
    if failable {
      return
"""
guard let value: \(name.text) = \(throwing ? "try " : "").\(initName)(\(params)) else { return 0 }
let ptr = UnsafeMutablePointer<\(name.text)>.allocate(capacity: 1)
ptr.initialize(to: value)
return JavaLong(Int(bitPattern: ptr))
"""
    }
    return
"""
let ptr = UnsafeMutablePointer<\(name.text)>.allocate(capacity: 1)
ptr.initialize(to: \(throwing ? "try " : "").\(initName)(\(params)))
return JavaLong(Int(bitPattern: ptr))
"""
  }
}



extension JvmValueTypeDeclSyntax {
  func expandJavaObjectDeclsAsClass(in context: some MacroExpansionContext) throws -> String {
    // A serialized peer holds fields, not an address, so there is no `_self`
    // to derive and no borrow to hand out. What remains is the pair of
    // conversions.
    if isSerialized {
      // Not reconstructible: emit `toJavaObject` only. The missing
      // `fromJavaObject` makes the JObjectConvertible conformance fail to
      // compile, which names the type and points the author at the one file
      // where a hand-written conversion belongs. Emitting a fatalError instead
      // would push the same problem to runtime and collide with any
      // hand-written version.
      guard isSerializedReconstructible else {
        return
"""
public func toJavaObject() -> JavaObject? {
  \(expandToJavaObject(in: context))
}
"""
      }

      // Assign every stored property from its Java getter. Computed properties
      // are marshalled outbound and skipped here, since there is nothing to
      // assign. The type of each `call` is inferred from the property being
      // assigned, so a nested peer recurses through its own `fromJavaObject`.
      let assignments = serializedStoredProperties.map {
        "  self.\($0.name) = _jvmSource.call(method: __JClass__.get\($0.capitalizedName))"
      }.joined(separator: "\n")

      return
"""
public init(_jvmFrom _jvmSource: JObject) {
\(assignments)
}

public static func fromJavaObject(_ obj: JavaObject?) -> Self {
  guard let obj else {
    fatalError("\(typeName).fromJavaObject received null")
  }
  return Self(_jvmFrom: JObject(obj))
}

public func toJavaObject() -> JavaObject? {
  \(expandToJavaObject(in: context))
}
"""
    }

    return
"""
private static func _self(_ obj: JavaObject?) -> UnsafeMutablePointer<\(typeName)> {
  let ptr: JavaLong = JObject(obj!).call(method: "_ptr")
  return _self(ptr) 
}

private static func _self(_ ptr: JavaLong) -> UnsafeMutablePointer<\(typeName)> {
  return UnsafeMutablePointer<\(typeName)>(bitPattern: Int(truncatingIfNeeded: ptr))! 
}

public static func fromJavaObject<R>(_ obj: JavaObject?, closure: (UnsafeMutablePointer<\(typeName)>) -> R) -> R {
  let _self = _self(obj)
  return closure(_self)
}

public static func fromJavaObject(_ obj: JavaObject?) -> Self {
  return _self(obj).pointee
}

public func toJavaObject() -> JavaObject? {
  \(expandToJavaObject(in: context))
}
"""
  }

  func expandCtorDeclsAsClass(in context: some MacroExpansionContext) throws -> String {
    // Nothing here applies to a serialized peer: there is no allocation to
    // free (deinit_jni), no address to duplicate (copy_jni), and the CLI emits
    // no Java constructor backed by an `init0` native.
    if isSerialized { return "" }

    let initDecls = exportedDecls.initDecls.enumerated()
      .compactMap { i, decl in
        return context.executeAndWarnIfFails(at: decl) {
          return try decl.makeBridgingDecls(typeDecl: self, index: i)
        }
      }
      .joined(separator: "\n")

    let deinitDecls =
"""
fileprivate typealias deinit_jni_t = @convention(c)(UnsafeMutablePointer<JNIEnv>, JavaClass?, JavaLong) -> Void
fileprivate static let deinit_jni: deinit_jni_t = { _, _, ptr in
  guard let p = UnsafeMutablePointer<\(typeName)>(bitPattern: Int(ptr)) else { return }
  p.deinitialize(count: 1)
  p.deallocate()
}
"""

    // Structs only. Nothing registers this for an enum, so emitting it there
    // would be a dead symbol; see the copyNatives gate in JvmTypeDeclSyntax.
    let copyDecls = self is StructDeclSyntax ?
"""
fileprivate typealias copy_jni_t = @convention(c)(UnsafeMutablePointer<JNIEnv>, JavaObject?, JavaLong) -> JavaLong
fileprivate static let copy_jni: copy_jni_t = { _, _, ptr in
  guard let src = UnsafeMutablePointer<\(typeName)>(bitPattern: Int(truncatingIfNeeded: ptr)) else { return 0 }
  let dst = UnsafeMutablePointer<\(typeName)>.allocate(capacity: 1)
  dst.initialize(to: src.pointee)
  return JavaLong(Int(bitPattern: dst))
}
""" : ""

    return
"""
\(initDecls)
\(deinitDecls)
\(copyDecls)
"""
  }
}
