import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension VariableDeclSyntax {
  /// An accessor on a serialized peer takes no address: there is none. JNI
  /// hands the peer over as the receiver and the thunk rebuilds the Swift value
  /// from the marshalled fields, exactly as an instance method does.
  private func serializedReceiver(_ typeDecl: any JvmTypeDeclSyntax) -> Bool {
    typeDecl.serializedDispatchesInstanceMethods && !isStatic
  }

  private func paramTypes(_ typeDecl: any JvmTypeDeclSyntax) -> [String] {
    ["UnsafeMutablePointer<JNIEnv>"]
      + (isStatic ? ["JavaClass?"]
         : serializedReceiver(typeDecl) ? ["JavaObject?"]
         : ["JavaObject?", "JavaLong"])
  }

  private func closureParams(_ typeDecl: any JvmTypeDeclSyntax) -> [String] {
    ["_", serializedReceiver(typeDecl) ? "recv" : "_"]
      + (isStatic || serializedReceiver(typeDecl) ? [] : ["ptr"])
  }

  /// The pointer-backed shape. Used by the borrow, array-size and observation
  /// thunks, none of which a serialized peer ever gets: a borrow needs an
  /// address to lend, and `scopedBorrowable` excludes computed properties
  /// besides.
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
    let _self = (isStatic || serializedReceiver(typeDecl)) ? "" : "J"

    return try decls.flatMap { d -> [(javaName: String, bridgeName: String, sig: String)] in
      let jniType = try d.type.jniSignature()

      // A marshalled stored property reads as a plain field and writes through
      // a native, so it declares the setter alone.
      if d.marshalling != nil, serializedReceiver(typeDecl), !d.computed {
        guard !d.readonly else { return [] }
        return [(javaName: "set\(d.capitalizedName)Impl",
                 bridgeName: "\(d.name)_set_jni",
                 sig: "(\(_self)\(jniType))V")]
      }

      var decls = [(
        javaName: "get\(d.capitalizedName)Impl",
        bridgeName: "\(d.name)_get_jni",
        sig: "(\(_self))\(jniType)"
      )]

      if Self.scopedBorrowable(d, isStatic: isStatic) {
        decls.append((
          javaName: "unsafeWith\(d.capitalizedName)Impl",
          bridgeName: "\(d.name)_with_jni",
          sig: "(JLio/scade/swift4j/SwiftBorrow;)V"
        ))
      }

      if Self.scopedForEachable(d, isStatic: isStatic) {
        decls.append((
          javaName: "unsafeForEach\(d.capitalizedName)Impl",
          bridgeName: "\(d.name)_each_jni",
          sig: "(JLio/scade/swift4j/SwiftBorrow;)V"
        ))
        decls.append((
          javaName: "unsafeElementOf\(d.capitalizedName)Impl",
          bridgeName: "\(d.name)_element_jni",
          sig: "(JILio/scade/swift4j/SwiftBorrow;)V"
        ))
        decls.append((
          javaName: "sizeOf\(d.capitalizedName)Impl",
          bridgeName: "\(d.name)_size_jni",
          sig: "(J)I"
        ))
      }

      if !d.readonly {
        decls.append((
          javaName: "set\(d.capitalizedName)Impl",
          bridgeName: "\(d.name)_set_jni",
          sig: "(\(_self)\(jniType))V"
        ))
      }

      if d.observable(self) && typeDecl.isObservable {
        decls.append((
            javaName: "get\(d.capitalizedName)WithObservationTrackingImpl",
            bridgeName: "\(d.name)_get_with_observation_tracking_jni",
            sig: "(\(_self)Ljava/lang/Runnable;)\(jniType)"
          ))
      }

      return decls
    }
  }

  func makeBridgingDecls(typeDecl: any JvmTypeDeclSyntax) throws -> String {
    try decls.flatMap { decl -> [String] in
      if decl.marshalling != nil, serializedReceiver(typeDecl), !decl.computed {
        guard !decl.readonly else { return [] }
        return [try makeBridgingSetter(for: decl, in: typeDecl)]
      }
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

  /// The setter for a property that crosses as some other type.
  ///
  /// Converts the incoming value and writes that one field through the peer's
  /// unchecked `_setX`. It does not rebuild the receiver and does not copy
  /// anything else back, so no other member is read, written or replaced — a
  /// Kotlin reference to any of them is untouched by this call.
  ///
  /// `toSwift` throws, and the conversion is the only thing that can fail, so a
  /// value this side cannot represent reaches Kotlin as an exception at the
  /// line that wrote it.
  private func makeBridgingMarshalledSetter(for varDecl: VarDecl,
                                            in typeDecl: any JvmTypeDeclSyntax,
                                            marshalling: JvmMarshalling) throws -> String {
    let raw = "_set\(varDecl.capitalizedName)"
    // `value` arrives in its JNI representation; `fromJava` lifts it to the
    // declared Java-side type before the author's conversion sees it.
    let mapping = try varDecl.type.fromJava("value")
    let body =
"""
\(mapping.stmts.joined(separator: "\n  "))
do {
    let __converted = try (\(marshalling.toSwift.trimmedDescription))(\(mapping.mapped))
    JObject(recv!).call(method: __JClass__.\(raw),
                        [(\(marshalling.toJava.trimmedDescription))(__converted).toJavaParameter()])
  } catch {
    jni.throwException(error)
  }
"""
    return makeDecl("\(varDecl.name)_set_jni",
                    in: typeDecl,
                    paramTypes: paramTypes(typeDecl) + [try varDecl.type.jniType()],
                    returnType: "Void",
                    closureParams: closureParams(typeDecl) + ["value"],
                    body: body,
                    isReturning: false)
  }

  private func makeBridgingSetter(for varDecl: VarDecl, in typeDecl: any JvmTypeDeclSyntax) throws -> String {
    if let marshalling = varDecl.marshalling, serializedReceiver(typeDecl) {
      return try makeBridgingMarshalledSetter(for: varDecl, in: typeDecl, marshalling: marshalling)
    }

    // A computed setter on a serialized peer writes through to storage, so it
    // needs the copy-back a `mutating` method gets: the receiver is a temporary
    // rebuilt from the peer, and without the write-back the assignment lands on
    // it and the Java object is silently unchanged.
    let writesBack = serializedReceiver(typeDecl)
    if writesBack && !typeDecl.serializedSupportsMutation {
      throw JvmMacrosError.message(
        "computed `var \(varDecl.name)` cannot have its setter bridged on "
        + "`@jvm(serialized:)` type `\(typeDecl.typeName)`: the receiver is rebuilt from "
        + "the Java peer's fields, and the write cannot be copied back because at least "
        + "one stored property is `@nonjvm` (nothing to write to) or `let` (no setter). "
        + "Make it get-only, or mark it `@nonjvm`.")
    }

    let _self = isStatic ? "\(typeDecl.typeName).self"
      : writesBack ? "__self"
      : typeDecl.selfExpr

    let bridgeName = "\(varDecl.name)_set_jni"
    let paramTypes = paramTypes(typeDecl) + [try varDecl.type.jniType()]
    let returnType = "Void"
    let varParamName = "value"
    let closureParams = closureParams(typeDecl) + [varParamName]

    let mapping = try varDecl.type.fromJava(varParamName)
    let prologue = writesBack
      ? """
        var __self = \(typeDecl.typeName).fromJavaObject(recv)
  defer { __self.updateJavaObject(recv!) }

  """
      : ""

    // A property that crosses as some other type is written through the
    // author's `toSwift`, which can refuse a value this side cannot represent.
    // That is the caller's mistake, so it reaches Kotlin as an exception at the
    // line that wrote it rather than being stored and failing later.
    let assignment = varDecl.marshalling.map { marshalling in
"""
do {
    \(_self).\(varDecl.name) = try (\(marshalling.toSwift.trimmedDescription))(\(mapping.mapped))
  } catch {
    jni.throwException(error)
  }
"""
    } ?? "\(_self).\(varDecl.name) = \(mapping.mapped)"

    let body =
"""
\(prologue)\(mapping.stmts.joined(separator: "\n  "))
\(assignment)
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
    let _self = isStatic ? "\(typeDecl.typeName).self"
      : serializedReceiver(typeDecl) ? "\(typeDecl.typeName).fromJavaObject(recv)"
      : typeDecl.selfExpr

    let bridgeName = "\(varDecl.name)_get_jni"
    let paramTypes = paramTypes(typeDecl)
    let returnType = try varDecl.type.jniType()
    let closureParams = closureParams(typeDecl)
    
    let mapping = try varDecl.type.toJava(varDecl.javaValue(of: _self))
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

  /// Yields one element of an array property, addressed by index. This is what
  /// makes reaching into a long array O(1) instead of O(n).
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

  /// The element count alone, so a caller can bound a loop without marshalling
  /// the array to find out how long it is.
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

    let mapping = try varDecl.type.toJava(varDecl.javaValue(of: _self))
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
