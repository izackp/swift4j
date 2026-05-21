import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension FunctionDeclSyntax {
  /// True if `name.text` is a Swift operator (non-identifier characters).
  /// Operators like `==`, `<`, `+` cannot be used as Swift identifiers in
  /// generated JNI thunk names, so they are mapped via `bridgeName`.
  var isOperator: Bool {
    return name.text.unicodeScalars.contains { !($0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")) }
  }

  /// Legal Swift/Java identifier derived from `name.text`.
  /// For operators, returns a Java-friendly name (e.g. `equals`, `lessThan`).
  /// For regular funcs, returns `name.text` unchanged.
  var bridgeName: String {
    switch name.text {
    case "==": return "equals"
    case "!=": return "notEquals"
    case "<":  return "lessThan"
    case ">":  return "greaterThan"
    case "<=": return "lessThanOrEqual"
    case ">=": return "greaterThanOrEqual"
    case "+":  return "plus"
    case "-":  return "minus"
    case "*":  return "times"
    case "/":  return "div"
    case "%":  return "mod"
    case "&":  return "and"
    case "|":  return "or"
    case "^":  return "xor"
    case "<<": return "shl"
    case ">>": return "shr"
    default:   return name.text
    }
  }

  func jniSignature() throws -> String {
    let params = try (isStatic ? [] : ["J"]) + signature.jniSignatures()
    let returnSig = isAsync ? "Ljava/util/concurrent/CompletableFuture;" : try signature.returnClause?.type.jniSignature() ?? "V"
    return "(\(params.joined()))\(returnSig)"
  }

  func makeBridgingDecls(typeDecl: any JvmTypeDeclSyntax, num: Int? = nil) throws -> String {
    let paramTypes = try
      ["UnsafeMutablePointer<JNIEnv>"]
        + (isStatic ? ["JavaClass?"] : ["JavaObject?", "JavaLong"])
        + signature.jniTypes()

    let returnType = isAsync ? "JavaObject" : try signature.returnClause?.type.jniType() ?? "Void"

    let closureParams = try ["_", "_"]
        + (isStatic ? [] : ["ptr"])
        + signature.jniParams()

    let _self = isStatic
      ? "\(typeDecl.typeName).self"
      : typeDecl.selfExpr

    var name = bridgeName

    if let num = num {
      name += "_\(num)"
    }

    return
"""
fileprivate typealias \(name)_jni_t = @convention(c)(\(paramTypes.joined(separator: ", "))) -> \(returnType)
fileprivate static let \(name)_jni: \(name)_jni_t = {\(closureParams.joined(separator: ", ")) in
  \(wrapBody(try makeBridgingFunctionBody(selfExpr: _self), in: typeDecl))
}
"""
  }

  func makeBridgingFunctionBody(selfExpr: String) throws -> String {
    var stmts: [String] = []
    var post: MappingRetType.PostFunc? = nil
    var call: String

    if isAsync {
      // Pre-decode each inbound param synchronously in the JNI entry frame.
      // Inbound JNI object/array refs are local refs owned by the calling
      // thread's transition frame. Inlining decodes inside the
      // `execWithFuture { … }` closure runs them on Task.detached, where
      // the caller's frame has already returned and the refs are dead →
      // CheckJNI aborts with "invalid JNI transition frame reference".
      var asyncArgs: [String] = []
      for param in signature.parameters {
        guard let pname = param.name else {
          throw JvmMacrosError.message("Unsupported function parameter syntax")
        }
        let m = try param.type.fromJava(pname)
        let local = "__pre_\(pname)"
        // m.stmts may bind helper locals (e.g. `_tags` for array decoded
        // from JavaObject) that m.mapped then references. Emit them first.
        stmts.append(contentsOf: m.stmts)
        stmts.append("let \(local) = \(m.mapped)")
        if let p = m.post {
          post = (post == nil) ? p : { p(post!($0)) }
        }
        if let passedName = param.passedName {
          asyncArgs.append("\(passedName): \(local)")
        } else {
          asyncArgs.append(local)
        }
      }
      let argList = asyncArgs.joined(separator: ", ")
      if isOperator {
        if asyncArgs.count == 2 {
          call = "(\(asyncArgs[0]) \(name.text) \(asyncArgs[1]))"
        } else if asyncArgs.count == 1 {
          call = "(\(name.text)\(asyncArgs[0]))"
        } else {
          call = "\(selfExpr).\(name.text)(\(argList))"
        }
      } else {
        call = "\(selfExpr).\(name.text)(\(argList))"
      }
    } else {
      let mapping = try signature.paramsMapping()
      stmts = mapping.stmts
      post = mapping.post
      if isOperator {
        // Swift forbids calling operators as `Type.==(a, b)`. Emit operator
        // syntax `(a OP b)` for binary, `(OP a)` for unary.
        let mapped = mapping.mapped
        let parts = mapped.split(separator: ",", maxSplits: 1).map { String($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 {
          call = "(\(parts[0]) \(name.text) \(parts[1]))"
        } else if parts.count == 1 {
          call = "(\(name.text)\(parts[0]))"
        } else {
          call = "\(selfExpr).\(name.text)(\(mapped))"
        }
      } else {
        call = "\(selfExpr).\(name.text)(\(mapping.mapped))"
      }
    }

    if isAsync {
      call = "await \(call)"
    }

    if isThrowing {
      call = "try \(call)"
    }

    if let retType = signature.returnClause?.type {
      if isAsync {
        // For async fns, the Swift value is passed unencoded to
        // execWithFuture's generic-T overload, which performs
        // `.toJavaObject()` + `NewGlobalRef` atomically on the same
        // thread/frame. Encoding here would create a JNI local ref that
        // Swift concurrency may then carry across an executor hop before
        // promotion → "invalid JNI transition frame reference" abort.
        call = "return \(call)"
      } else {
        let ret_mapping = try retType.toJava(call)

        call = "return \(ret_mapping.mapped)"
        stmts.append(contentsOf: ret_mapping.stmts)

        if let ret_post = ret_mapping.post {
          post = (post == nil) ? ret_post : { ret_post(post!($0)) }
        }
      }
    }

    if isAsync {
      call =
"""
  return execWithFuture {
    \(call)
  }
"""

    } else if isThrowing {
      call =
"""
  do { 
    \(call) 
  } catch { 
    jni.throwException(error) 
  }
"""
      if let retDefault = try signature.returnClause?.type.jniTypeDefaultValue() {
        call =
"""
  \(call)
  return \(retDefault)
"""
      }
    }

    let body =
"""
  \(stmts.joined(separator: "\n  "))
  \(call)
"""

    return (post == nil) ? body : post!(body)
  }
}
