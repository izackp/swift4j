import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension IdentifierTypeSyntax: JvmMappedTypeSyntax {
  var isVoid: Bool {
    name.text == "Void"
  }

  var isPrimitive: Bool {
    switch name.text {
    case "Void", "Bool", "Int", "Int64", "Int32", "Int16", "Int8",
         "UInt", "UInt64", "UInt32", "UInt16", "UInt8",
         "Float", "Double": true
    default: false
    }
  }

  func jniSignature(primitivesAsObjects: Bool) -> String {
    switch name.text {
    case "Void": "V"
    case "Bool": primitivesAsObjects ? "Ljava/lang/Boolean;" : "Z"
    // Unsigned types share JNI wire format with their signed counterparts.
    // Bridge code in Primitives+JConvertible.swift throws
    // IllegalArgumentException on out-of-range values.
    case "Int", "Int64", "UInt", "UInt64": primitivesAsObjects ? "Ljava/lang/Long;" : "J"
    case "Int32", "UInt32": primitivesAsObjects ? "Ljava/lang/Integer;" : "I"
    case "Int16", "UInt16": primitivesAsObjects ? "Ljava/lang/Short;" : "S"
    case "Int8", "UInt8": primitivesAsObjects ? "Ljava/lang/Byte;" : "B"
    case "Float": primitivesAsObjects ? "Ljava/lang/Float;" : "F"
    case "Double": primitivesAsObjects ? "Ljava/lang/Double;" : "D"
    case "String": "Ljava/lang/String;"
    // Foundation.Data bridges to Java byte[]. The JNI signature is the
    // raw array form "[B", not the class-wrapped "L[B;" the default
    // branch would emit.
    case "Data": "[B"
      default: "L\\(\(description).javaName);" //"\\(\(name.text).javaSignature)"
    }
  }

  func jniType(primitivesAsObjects: Bool) -> String {
    switch name.text {
    case "Void": "Void"
    case "Bool": primitivesAsObjects ? "JavaObject" : "JavaBoolean"
    case "Int", "Int64", "UInt", "UInt64": primitivesAsObjects ? "JavaObject" : "JavaLong"
    case "Int32", "UInt32": primitivesAsObjects ? "JavaObject" : "JavaInt"
    case "Int16", "UInt16": primitivesAsObjects ? "JavaObject" : "JavaShort"
    case "Int8", "UInt8": primitivesAsObjects ? "JavaObject" : "JavaByte"
    case "Float": primitivesAsObjects ? "JavaObject" : "JavaFloat"
    case "Double": primitivesAsObjects ? "JavaObject" : "JavaDouble"
    default: "JavaObject?"
    }
  }

  func jniTypeDefaultValue(primitivesAsObjects: Bool) throws -> String {
    if !isPrimitive || primitivesAsObjects {
      return "nil"
    } else {
      return "\(jniType(primitivesAsObjects: primitivesAsObjects))()"
    }
  }

  func toJava(_ expr: String, primitivesAsObjects: Bool) -> MappingRetType {
    if isPrimitive && !primitivesAsObjects {
      switch name.text {
        case "Int":
          return MappingRetType(mapped: "JavaLong(\(expr))")
        case "Bool":
          return MappingRetType(mapped: "JavaBoolean(\(expr) ? 1 : 0)")
        case "UInt", "UInt64":
          return MappingRetType(mapped: "\(expr).toJavaLong()")
        case "UInt32":
          return MappingRetType(mapped: "\(expr).toJavaInt()")
        case "UInt16":
          return MappingRetType(mapped: "\(expr).toJavaShort()")
        case "UInt8":
          return MappingRetType(mapped: "\(expr).toJavaByte()")
        default:
          return MappingRetType(mapped: expr)
      }
    } else {
      return MappingRetType(mapped: "\(expr).toJavaObject()")
    }
  }

  func fromJava(_ expr: String, primitivesAsObjects: Bool, optional: Bool) -> MappingRetType {
    if isPrimitive && !primitivesAsObjects {
      switch name.text {
          case "Int":
          return MappingRetType(mapped: "Int(\(expr))")
        case "Bool":
          return MappingRetType(mapped: "(\(expr) == 1)")
        case "UInt", "UInt64":
          return MappingRetType(mapped: "UInt64.fromJavaLong(\(expr))")
        case "UInt32":
          return MappingRetType(mapped: "UInt32.fromJavaInt(\(expr))")
        case "UInt16":
          return MappingRetType(mapped: "UInt16.fromJavaShort(\(expr))")
        case "UInt8":
          return MappingRetType(mapped: "UInt8.fromJavaByte(\(expr))")
        default:
          return MappingRetType(mapped: expr)
      }

    } else if isInOut {
      return MappingRetType(mapped: "&$0.pointee") {
"""
\(name.text).fromJavaObject(\(expr)) {
  \($0)
}
"""
      }
    } else {
      let _type = _syntaxNode.trimmedDescription + (optional ? "?" : "")
      let _expr = "\(_type).fromJavaObject(\(expr))"

      guard let paramName = typedEntityName else {
        return MappingRetType(mapped: _expr)
      }

      return MappingRetType(mapped: "_\(paramName)",
                            stmts: ["let _\(paramName) = \(_expr)"])
    }
  }
}

