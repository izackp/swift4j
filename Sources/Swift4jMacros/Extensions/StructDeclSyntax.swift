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
      let args = serializedProperties.map { prop -> String in
        prop.type.is(OptionalTypeSyntax.self)
          ? "JavaParameter(object: \(prop.name).toJavaObject())"
          : "\(prop.name).toJavaParameter()"
      }
      return
"""
  return \(typeName).javaClass.create(ctor: __JClass__.ctor, [\(args.joined(separator: ", "))])
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


