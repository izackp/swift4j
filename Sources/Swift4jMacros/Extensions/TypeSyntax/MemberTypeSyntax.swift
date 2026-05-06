// Bridges qualified type access like `Server.Info` or `Foo.Bar.Baz` for
// `@jvm`-annotated types nested inside an enum, struct, class, or
// extension. The bridge defers to the runtime contract `@jvm` types
// expose: static `javaName`, static `fromJavaObject`, instance
// `toJavaObject()`. The full member-access expression is used verbatim
// as the Swift type reference so nested lookup compiles.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension MemberTypeSyntax: JvmMappedTypeSyntax {
  func jniSignature(primitivesAsObjects: Bool) throws -> String {
    return "L\\(\(trimmedDescription).javaName);"
  }

  func jniType(primitivesAsObjects: Bool) throws -> String {
    return "JavaObject?"
  }

  func jniTypeDefaultValue(primitivesAsObjects: Bool) throws -> String {
    return "nil"
  }

  func toJava(_ expr: String, primitivesAsObjects: Bool) throws -> MappingRetType {
    return MappingRetType(mapped: "\(expr).toJavaObject()")
  }

  func fromJava(_ expr: String, primitivesAsObjects: Bool, optional: Bool) throws -> MappingRetType {
    let _type = trimmedDescription + (optional ? "?" : "")
    let _expr = "\(_type).fromJavaObject(\(expr))"

    guard let paramName = typedEntityName else {
      return MappingRetType(mapped: _expr)
    }

    return MappingRetType(mapped: "_\(paramName)",
                          stmts: ["let _\(paramName) = \(_expr)"])
  }
}
