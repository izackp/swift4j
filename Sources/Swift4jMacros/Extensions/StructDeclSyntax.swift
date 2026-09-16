import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension StructDeclSyntax: JvmValueTypeDeclSyntax {
  func expandToJavaObject(in context: some MacroExpansionContext) -> String {
    // Serialized: copy the fields into a new Java object and hand it over.
    // Nothing is allocated on the native heap, so nothing has to be reclaimed
    // and the GC's blindness to Swift object sizes stops mattering.
    //
    // Argument order is declaration order, matching the constructor
    // `ClassGenerator.generateSerialized` emits. Neither side sorts.
    //
    // `toJavaParameter()` covers primitives and `JObjectConvertible` — so a
    // nested serialized member recurses into its own copy, and a nested handle
    // member boxes a pointer exactly as it does today.
    //
    // Optionals are boxed explicitly rather than going through
    // `toJavaParameter()`. `Optional` conforms to `JParameterConvertible` only
    // where `Wrapped: JObjectConvertible`, so an optional primitive — `Int32?`,
    // the `Server.Subject.period` shape — has no witness, and Swift will not
    // take a second overlapping conditional conformance for
    // `JPrimitiveConvertible`. Boxing is what the Java side expects anyway:
    // the constructor takes `Integer`, not `int`, for a nullable field.
    if isSerialized {
      var args = serializedProperties.map { prop -> String in
        let value = prop.javaValue(of: "self")
        return prop.type.is(OptionalTypeSyntax.self)
          ? "JavaParameter(object: \(value).toJavaObject())"
          : "\(value).toJavaParameter()"
      }
      // Selects the unchecked constructor. These values came from Swift, so
      // re-running the conversions the checked one performs would cost a JNI
      // round trip per marshalled field to reach a conclusion already known.
      if serializedHasCheckedCtor {
        args.append("false.toJavaParameter()")
      }
      return
"""
  let __jvmFramePushed = jni.PushLocalFrame(\(max(args.count, 1) + 4)) >= 0
  let __jvmPeer = \(typeName).javaClass.create(ctor: __JClass__.ctor, [\(args.joined(separator: ", "))])
  guard __jvmFramePushed else { return __jvmPeer }
  return jni.PopLocalFrame(__jvmPeer)
"""
    }

    return
"""
  let ptr = UnsafeMutablePointer<\(name.text)>.allocate(capacity: 1)
  ptr.initialize(to: self)
  return \(typeName).javaClass.callStaticObjectMethod(method: __JClass__.fromPtr, [Int(bitPattern: ptr).toJavaParameter()])
"""
  }
  

}


