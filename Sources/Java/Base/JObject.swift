//
//  JObject.swift
//  Java
//
//  Created by Grigory Markin on 01.06.18.
//

import CJNI


public class JObject: @unchecked Sendable {
  public let ptr: JavaObject
  public let weak: Bool

  public lazy var cls: JClass = {
    JClass(jni.CallObjectMethod(ptr, Object__getClass, [])!)
  }()
  
  public init(_ ptr: JavaObject, weak: Bool = false) {
    self.ptr = weak ? jni.NewWeakGlobalRef(ptr)! : jni.NewGlobalRef(ptr)!
    self.weak = weak
  }
    
  deinit {
    if self.weak {
      jni.DeleteWeakGlobalRef(self.ptr)
    } else {
      jni.DeleteGlobalRef(self.ptr)
    }
  }

  /// A reference usable in JNI calls, or `nil` when a weak peer has already
  /// been collected.
  ///
  /// `ptr` holds a `jweak` in weak mode, and a weak global may not be passed to
  /// JNI directly — it has to be promoted to a local ref, which also reports
  /// whether the object is still alive. The returned local belongs to the
  /// current JNI frame; use ``withObject(_:)`` instead when the reference does
  /// not escape, so it is released immediately rather than at frame exit.
  public func localRef() -> JavaObject? {
    guard weak else { return ptr }
    return jni.NewLocalRef(ptr)
  }

  /// Runs `body` against a promoted reference, releasing it afterwards.
  /// Returns `nil` without calling `body` if a weak peer has been collected.
  public func withObject<T>(_ body: (JavaObject) throws -> T) rethrows -> T? {
    guard weak else { return try body(ptr) }
    guard let local = jni.NewLocalRef(ptr) else { return nil }
    defer { jni.DeleteLocalRef(local) }
    return try body(local)
  }



  public func get<T: JConvertible>(field: JavaFieldID) -> T {
    return T.fromField(field, of: ptr)
  }
    
  public func get<T: JConvertible>(field: String, sig: String) -> T {
    guard let fieldId = cls.getFieldID(name: field, sig: sig) else {
      fatalError("Cannot find field \(field) with signature \(sig)")
    }
    return self.get(field: fieldId)
  }
  
  public func get<T: JConvertible>(field: String) -> T {
    return self.get(field: field, sig: T.javaSignature)  
  }
  
  
  
  public func set<T: JConvertible>(field: JavaFieldID, value: T) {
    value.toField(field, of: ptr)
  }
    
  public func set<T: JConvertible>(field: String, sig: String, value: T) {
    guard let fieldId = cls.getFieldID(name: field, sig: sig) else {
      fatalError("Cannot find field \(field) with signature \(sig)")
    }
    value.toField(fieldId, of: ptr)
  }
  
  public func set<T: JConvertible>(field: String, value: T) {
    self.set(field: field, sig: T.javaSignature, value: value)
  }
  


  public func call(method: JavaMethodID, _ args : [JavaParameter]) -> Void {
    jni.CallVoidMethod(ptr, method, args)
  }
  
  public func call(method: String, sig: String, _ args : [JavaParameter]) -> Void {
    guard let methodId = cls.getMethodID(name: method, sig: sig) else  {
      fatalError("Cannot find method \"\(method)\" with signature \"\(sig)\"")
    }
    return call(method: methodId, args) as Void
  }

  public func call(method: JavaMethodID, _ args : JParameterConvertible...) -> Void {
    call(method: method, args.map{$0.toJavaParameter()}) as Void
  }

  public func call(method: String, sig: String, _ args : JParameterConvertible...) -> Void {
    call(method: method, sig: sig, args.map{$0.toJavaParameter()}) as Void
  }

  public func call(method: String, _ args : JConvertible...) -> Void {
    let sig = "(\(args.reduce("", { $0 + type(of: $1).javaSignature})))V"
    return call(method: method, sig: sig, args.map{$0.toJavaParameter()}) as Void
  }



  public func call<T>(method: JavaMethodID, _ args: [JavaParameter]) -> T where T: JConvertible {
    return T.fromMethod(method, on: ptr, args: args)
  }
  
  public func call<T>(method: String, sig: String, _ args: [JavaParameter]) -> T where T: JConvertible {
    guard let methodId = cls.getMethodID(name: method, sig: sig) else  {
      let methods = cls.call(method: "getMethods", sig: "()[Ljava/lang/reflect/Method;") as [Object]
      let methods_sigs: [String] = methods.map{$0.javaObject.call(method: "toGenericString")}

      fatalError("Cannot find method \"\(method)\" with signature \"\(sig)\". Available methods: \n \(methods_sigs.joined(separator: "\n"))")
    }
    return call(method: methodId, args)
  }

  public func call<T>(method: JavaMethodID, _ args: JParameterConvertible...) -> T where T: JConvertible {
    return call(method: method, args.map{$0.toJavaParameter()})
  }
  
  public func call<T>(method: String, sig: String, _ args: JParameterConvertible...) -> T where T: JConvertible {
    return call(method: method, sig: sig, args.map{$0.toJavaParameter()})
  }

  public func call<T>(method: String, _ args : JConvertible...) -> T where T: JConvertible {
    let sig = "(\(args.reduce("", { $0 + type(of: $1).javaSignature})))\(T.javaSignature)"
    return call(method: method, sig: sig, args.map{$0.toJavaParameter()})
  }



  public func callObjectMethod(method: JavaMethodID, _ args : [JavaParameter]) -> JavaObject? {
    return jni.CallObjectMethod(ptr, method, args)
  }

  public func callObjectMethod(method: String, sig: String, _ args : [JavaParameter]) -> JavaObject? {
    guard let methodId = cls.getMethodID(name: method, sig: sig) else  {
      fatalError("Cannot find method \"\(method)\" with signature \"\(sig)\"")
    }
    return callObjectMethod(method: methodId, args) as JavaObject?
  }
}




fileprivate let Object__class = JClass(jni.FindClass("java/lang/Object")!)
fileprivate let Object__getClass = Object__class.getMethodID(name: "getClass", sig: "()Ljava/lang/Class;")!

