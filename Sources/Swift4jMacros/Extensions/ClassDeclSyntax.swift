import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension ClassDeclSyntax: JvmTypeDeclSyntax {

  func expandJavaObjectDecls(in context: some MacroExpansionContext) throws -> String {
    if isSerialized {
      return try expandSerializedJavaObjectDecls(in: context)
    }
    return
"""
private let jref: JObjectRef<\(typeName)> = .init()

private nonisolated static func _self(_ obj: JavaObject?) -> Self {
  let ptr: JavaLong = JObject(obj!).call(method: "_ptr")
  return _self(ptr)
}

private nonisolated static func _self(_ ptr: JavaLong) -> Self {  
  return unsafeBitCast(Int(truncatingIfNeeded: ptr), to: Unmanaged<Self>.self).takeUnretainedValue()
}

public nonisolated static func fromJavaObject<R>(_ obj: JavaObject?, closure: (UnsafeMutablePointer<\(typeName)>) -> R) -> R {
  var _self = _self(obj)
  return closure(&_self)
}

public nonisolated static func fromJavaObject(_ obj: JavaObject?) -> Self {
  return _self(obj)  
}

public nonisolated func toJavaObject() -> JavaObject? {
  return jref.from(self)
}
"""
  }
  
  /// A serialized class peer is a snapshot: the fields are copied out, and the
  /// object the copy came from is not reachable from it. Reading one back
  /// builds a *new* instance, which is why the initializer is `required` on a
  /// non-final class — `fromJavaObject` returns `Self`.
  func expandSerializedJavaObjectDecls(in context: some MacroExpansionContext) throws -> String {
    guard isSerializedReconstructible else {
      return
"""
public func toJavaObject() -> JavaObject? {
\(expandSerializedToJavaObject(in: context))
}
"""
    }

    let assignments = serializedProperties.map { prop -> String in
      let getter = "__JClass__.get\(prop.capitalizedName)"
      if let marshalling = prop.marshalling {
        let raw = "(_jvmSource.call(method: \(getter)) as \(marshalling.javaType.trimmedDescription))"
        return "  self.\(prop.name) = try! \(prop.swiftValue(from: raw))"
      }
      guard let wrapped = prop.type.as(OptionalTypeSyntax.self)?.wrappedType else {
        return "  self.\(prop.name) = _jvmSource.call(method: \(getter))"
      }
      return "  self.\(prop.name) = _jvmSource.callObjectMethod(method: \(getter), [])"
        + ".map { \(wrapped.trimmedDescription).fromJavaObject($0) }"
    }.joined(separator: "\n")

    let isFinal = modifiers.contains { $0.name.tokenKind == .keyword(.final) }

    return
"""
public \(isFinal ? "" : "required ")init(_jvmFrom _jvmSource: JObject) {
  let __jvmFramePushed = jni.PushLocalFrame(\(max(serializedProperties.count, 1) + 4)) >= 0
  defer { if __jvmFramePushed { jni.PopLocalFrame() } }
\(assignments)
}

public static func fromJavaObject(_ obj: JavaObject?) -> Self {
  guard let obj else {
    fatalError("\(typeName).fromJavaObject received null")
  }
  return Self(_jvmFrom: JObject(obj))
}

public func toJavaObject() -> JavaObject? {
\(expandSerializedToJavaObject(in: context))
}
"""
  }

  private func expandSerializedToJavaObject(in context: some MacroExpansionContext) -> String {
    let args = serializedProperties.map { prop -> String in
      let value = prop.javaValue(of: "self")
      return prop.type.is(OptionalTypeSyntax.self)
        ? "JavaParameter(object: \(value).toJavaObject())"
        : "\(value).toJavaParameter()"
    }

    return
"""
  let __jvmFramePushed = jni.PushLocalFrame(\(max(args.count, 1) + 4)) >= 0
  let __jvmPeer = \(typeName).javaClass.create(ctor: __JClass__.ctor, [\(args.joined(separator: ", "))])
  guard __jvmFramePushed else { return __jvmPeer }
  return jni.PopLocalFrame(__jvmPeer)
"""
  }

  func expandCtorDecls(in context: some MacroExpansionContext) throws -> String {
    // Nothing here applies to a serialized peer: no address is handed out, so
    // there is no allocation to retain and none to release.
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
fileprivate nonisolated static let deinit_jni: deinit_jni_t = { _, _, ptr in
  let _self = unsafeBitCast(Int(truncatingIfNeeded: ptr), to: Unmanaged<\(typeName)>.self)
  _self.takeUnretainedValue().jref.release()
  _self.release()  
}
"""

    return
"""
\(initDecls)
\(deinitDecls)
"""

  }

  func expandInitCall(params: String, throwing: Bool, failable: Bool, initName: String) -> String {
    if failable {
      return
"""
guard let obj = \(throwing ? "try ": "")\(name.text)(\(params)) else { return 0 }
return JavaLong(Int(bitPattern: Unmanaged.passRetained(obj).toOpaque()))
"""
    }
    return
"""
let obj = \(throwing ? "try ": "")\(name.text)(\(params))
return JavaLong(Int(bitPattern: Unmanaged.passRetained(obj).toOpaque()))
"""
  }
}


