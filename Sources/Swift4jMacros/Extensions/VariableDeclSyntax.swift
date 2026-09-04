import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension VariableDeclSyntax {
  private var defaultParamTypes: [String] {
    ["UnsafeMutablePointer<JNIEnv>"] + (isStatic ? ["JavaClass?"] : ["JavaObject?", "JavaLong"])
  }

  private var defaultClosureParams: [String] {
    ["_", "_"] + (isStatic ? [] : ["ptr"])
  }

  /// Whether this property gets a scoped-borrow native (`unsafeWith<X>Impl`).
  ///
  /// Purely syntactic, because the macro cannot resolve what `Foo` names. The
  /// same rule is duplicated in swift4j-cli's VarGenerator and the two MUST
  /// agree: the CLI declares the native, the macro registers it, and
  /// `RegisterNatives` fails the whole batch on any mismatch (R2).
  ///
  /// Deliberately over-broad. It admits types that bridge by conversion rather
  /// than pointer-boxing (`Date`, `URL`), which the Swift side handles by
  /// overload resolution on `JvmPointerBoxed` and the CLI handles by declaring
  /// the native without exposing a public wrapper for it.
  static func scopedBorrowable(_ varDecl: VarDecl, isStatic: Bool) -> Bool {
    guard !isStatic, !varDecl.readonly, !varDecl.computed else { return false }
    return borrowableType(varDecl.type)
  }

  /// An `Optional<T>` is borrowable exactly when `T` is: `&value!` addresses
  /// the payload in place, so there is a single peer to hand out. Nesting is
  /// not unwrapped repeatedly — `T??` has no sensible single borrow.
  private static func borrowableType(_ type: TypeSyntax) -> Bool {
    let name: String
    if let ident = type.as(IdentifierTypeSyntax.self) {
      guard !ident.isPrimitive else { return false }
      name = ident.name.text
    } else if type.is(MemberTypeSyntax.self) {
      // Namespaced @jvm type, e.g. `Server.Subject`.
      return true
    } else if let optional = type.as(OptionalTypeSyntax.self) {
      let wrapped = optional.wrappedType
      guard !wrapped.is(OptionalTypeSyntax.self) else { return false }
      return borrowableType(wrapped)
    } else {
      // Array, Dictionary, function types: no single peer to borrow.
      return false
    }
    return name != "String" && name != "Data"
  }

  /// Whether this property gets `unsafeForEach<X>Impl`.
  ///
  /// Separate from `scopedBorrowable` because the shapes differ: a scope yields
  /// one peer, this yields one per element. An array of a non-borrowable
  /// element is excluded for the same reasons a bare property of it would be.
  static func scopedForEachable(_ varDecl: VarDecl, isStatic: Bool) -> Bool {
    guard !isStatic, !varDecl.readonly, !varDecl.computed else { return false }
    guard let array = varDecl.type.as(ArrayTypeSyntax.self) else { return false }
    return borrowableType(array.element)
  }

  func bridgings(typeDecl: any JvmTypeDeclSyntax) throws -> [(javaName: String, bridgeName: String, sig: String)] {
    let _self = isStatic ? "" : "J"

    return try decls.flatMap {
      let jniType = try $0.type.jniSignature()
      var decls = [(
        javaName: "get\($0.capitalizedName)Impl",
        bridgeName: "\($0.name)_get_jni",
        sig: "(\(_self))\(jniType)"
      )]

      if Self.scopedBorrowable($0, isStatic: isStatic) {
        decls.append((
          javaName: "unsafeWith\($0.capitalizedName)Impl",
          bridgeName: "\($0.name)_with_jni",
          sig: "(JLio/scade/swift4j/SwiftBorrow;)V"
        ))
      }

      if Self.scopedForEachable($0, isStatic: isStatic) {
        decls.append((
          javaName: "unsafeForEach\($0.capitalizedName)Impl",
          bridgeName: "\($0.name)_each_jni",
          sig: "(JLio/scade/swift4j/SwiftBorrow;)V"
        ))
        decls.append((
          javaName: "unsafeElementOf\($0.capitalizedName)Impl",
          bridgeName: "\($0.name)_element_jni",
          sig: "(JILio/scade/swift4j/SwiftBorrow;)V"
        ))
        decls.append((
          javaName: "sizeOf\($0.capitalizedName)Impl",
          bridgeName: "\($0.name)_size_jni",
          sig: "(J)I"
        ))
      }

      if !$0.readonly {
        decls.append((
          javaName: "set\($0.capitalizedName)Impl",
          bridgeName: "\($0.name)_set_jni",
          sig: "(\(_self)\(jniType))V"
        ))
      }

      if $0.observable(self) && typeDecl.isObservable {
        decls.append((
            javaName: "get\($0.capitalizedName)WithObservationTrackingImpl",
            bridgeName: "\($0.name)_get_with_observation_tracking_jni",
            sig: "(\(_self)Ljava/lang/Runnable;)\(jniType)"
          ))
      }

      return decls
    }
  }

  func makeBridgingDecls(typeDecl: any JvmTypeDeclSyntax) throws -> String {
    try decls.flatMap { decl -> [String] in
      var parts: [String] = [try makeBridgingGetter(for: decl, in: typeDecl)]
      if !decl.readonly {
        parts.append(try makeBridgingSetter(for: decl, in: typeDecl))
      }
      if Self.scopedBorrowable(decl, isStatic: isStatic) {
        parts.append(makeBridgingScopedBorrow(for: decl, in: typeDecl))
      }
      if Self.scopedForEachable(decl, isStatic: isStatic) {
        parts.append(makeBridgingScopedForEach(for: decl, in: typeDecl))
        parts.append(makeBridgingScopedElement(for: decl, in: typeDecl))
        parts.append(makeBridgingArraySize(for: decl, in: typeDecl))
      }
      if decl.observable(self) && typeDecl.isObservable {
        parts.append(try makeBridgingGetterWithObservationTracking(for: decl, in: typeDecl))
      }
      return parts
    }.joined(separator: "\n")
  }

  //MARK: - Setter

  private func makeBridgingSetter(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) throws -> String {
    let _self = isStatic ? "\(typeDecl.typeName).self" : typeDecl.selfExpr

    let bridgeName = "\(varDecl.name)_set_jni"
    let paramTypes = defaultParamTypes + [try varDecl.type.jniType()]
    let returnType = "Void"
    let varParamName = "value"
    let closureParams = defaultClosureParams + [varParamName]
    
    let mapping = try varDecl.type.fromJava(varParamName)
    let body =
"""
\(mapping.stmts.joined(separator: "\n  "))
\(_self).\(varDecl.name) = \(mapping.mapped)
"""

    return makeDecl(bridgeName,
                    in: typeDecl,
                    paramTypes: paramTypes,
                    returnType: returnType,
                    closureParams: closureParams,
                    body: body,
                    isReturning: false)
  }

  //MARK: - Getter

  private func makeBridgingGetter(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) throws -> String {
    let _self = isStatic ? "\(typeDecl.typeName).self" : typeDecl.selfExpr

    let bridgeName = "\(varDecl.name)_get_jni"
    let paramTypes = defaultParamTypes
    let returnType = try varDecl.type.jniType()
    let closureParams = defaultClosureParams
    
    let mapping = try varDecl.type.toJava("\(_self).\(varDecl.name)")
    let body =
"""
\(mapping.stmts.joined(separator: "\n  "))
return \(mapping.mapped)
"""

    return makeDecl(bridgeName,
                    in: typeDecl,
                    paramTypes: paramTypes,
                    returnType: returnType,
                    closureParams: closureParams,
                    body: body,
                    isReturning: true)
  }

  //MARK: - Scoped borrow

  /// Yields the property to a Java `SwiftBorrow` for the duration of the call.
  ///
  /// `withUnsafeMutablePointer(to:)` inside `_jvmScopedBorrow` is what makes
  /// this sound where an escaping interior pointer would not be: the address is
  /// only ever live inside the closure, which is exactly the JNI call. Swift's
  /// own `_modify` has the same shape.
  private func makeBridgingScopedBorrow(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) -> String {
    let _self = typeDecl.selfExpr

    return makeDecl("\(varDecl.name)_with_jni",
                    in: typeDecl,
                    paramTypes: defaultParamTypes + ["JavaObject?"],
                    returnType: "Void",
                    closureParams: defaultClosureParams + ["body"],
                    body: "_jvmScopedBorrow(&\(_self).\(varDecl.name), body)",
                    isReturning: false)
  }

  /// Yields each element of an array property to a Java `SwiftBorrow`, in
  /// place. Distinct from a scope over the array itself, which would hand Java
  /// a peer for `[T]` — a type with no bridged representation.
  private func makeBridgingScopedForEach(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) -> String {
    let _self = typeDecl.selfExpr

    return makeDecl("\(varDecl.name)_each_jni",
                    in: typeDecl,
                    paramTypes: defaultParamTypes + ["JavaObject?"],
                    returnType: "Void",
                    closureParams: defaultClosureParams + ["body"],
                    body: "_jvmScopedBorrowEach(&\(_self).\(varDecl.name), body)",
                    isReturning: false)
  }

  /// Yields one element of an array property, addressed by index, so a
  /// projection can be re-entered and land on the same element each time.
  private func makeBridgingScopedElement(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) -> String {
    let _self = typeDecl.selfExpr

    return makeDecl("\(varDecl.name)_element_jni",
                    in: typeDecl,
                    paramTypes: defaultParamTypes + ["JavaInt", "JavaObject?"],
                    returnType: "Void",
                    closureParams: defaultClosureParams + ["index", "body"],
                    body: "_jvmScopedBorrowElement(&\(_self).\(varDecl.name), Int(index), body)",
                    isReturning: false)
  }

  /// The element count alone. Without this the projecting getter would have to
  /// call the copying native just to learn the length, which would box the
  /// whole array — the exact cost projections exist to avoid.
  private func makeBridgingArraySize(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) -> String {
    let _self = typeDecl.selfExpr

    return makeDecl("\(varDecl.name)_size_jni",
                    in: typeDecl,
                    paramTypes: defaultParamTypes,
                    returnType: "JavaInt",
                    closureParams: defaultClosureParams,
                    body: "return JavaInt(\(_self).\(varDecl.name).count)",
                    isReturning: true)
  }

  //MARK: - Getter + Observation

  private func makeBridgingGetterWithObservationTracking(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) throws -> String {
    let _self = isStatic ? "\(typeDecl.typeName).self" : typeDecl.selfExpr

    let bridgeName = "\(varDecl.name)_get_with_observation_tracking_jni"
    let paramTypes = defaultParamTypes + ["JavaObject"]
    let returnType = try varDecl.type.jniType()
    let closureParams = defaultClosureParams + ["onChange"]

    let mapping = try varDecl.type.toJava("\(_self).\(varDecl.name)")
    let body =
"""
let _onChange = JObject(onChange) 
return withObservationTracking {
  \(mapping.stmts.joined(separator: "\n  "))
  return \(mapping.mapped)
} onChange: {
  _onChange.call(method: "run")
}
"""

    return makeDecl(bridgeName,
                    in: typeDecl,
                    paramTypes: paramTypes,
                    returnType: returnType,
                    closureParams: closureParams,
                    body: body,
                    isReturning: true)
  }

  private func makeDecl(_ bridgeName: String,
                        in typeDecl: any JvmTypeDeclSyntax,
                        paramTypes: [String],
                        returnType: String,
                        closureParams: [String],
                        body: String,
                        isReturning: Bool) -> String {
"""
fileprivate typealias \(bridgeName)_t = @convention(c)(\(paramTypes.joined(separator: ", "))) -> \(returnType)
fileprivate static let \(bridgeName): \(bridgeName)_t = {\(closureParams.joined(separator: ", ")) in    
  \(wrapBody(body, in: typeDecl))  
}
"""
  }

}
