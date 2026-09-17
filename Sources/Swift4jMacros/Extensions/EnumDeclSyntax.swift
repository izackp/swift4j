import SwiftSyntax

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension EnumDeclSyntax: JvmValueTypeDeclSyntax {
  func expandMembers(in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    // A serialized peer reads its payload out of its own Java fields, so there
    // is no native getter to back and nothing registers one.
    let caseGetters = isSerialized ? "" : try caseDecls().compactMap {
      try $0.makeBridgingGetterDecls(typeDecl: self)
    }.joined(separator: "\n")

    return try expandMembersDefault(in: context) + ["\(raw: caseGetters)"]
  }

  func expandJavaClassDecl(in context: some MacroExpansionContext) -> String {
    let caseJClassDecls: String
    if withAssociatedValues {
      let fqn = fqn(from: context)
      caseJClassDecls = caseDecls().map { c in
        let caseName = c.name.text
        let caseClass = fqn + "$" + caseName

        let jclassDecl =
"""
private static let \(caseName)_javaClass: JClass = {
  guard let cls = JClass(fqn: "\(caseClass)") else {
    fatalError("Could not find \(caseClass) class")
  }
  return cls
}()
"""
        // A serialized case is built through its own constructor, taking the
        // payload by value. A pointer-backed one is built from an address, so
        // it goes through the static `fromPtr` the Kotlin peer declares.
        guard isSerialized else {
          return
"""
\(jclassDecl)
private static let \(caseName)_fromPtr: JavaMethodID = {
  guard let mid = \(caseName)_javaClass.getStaticMethodID(name: "fromPtr", sig: "(J)L\(caseClass);") else {
    fatalError("Could not find \(caseClass).fromPtr")
  }
  return mid
}()
"""
        }
        guard !c.parameters.isEmpty else { return jclassDecl }

        let ctorSig = (try? c.serializedCtorSignature()) ?? "()V"
        return
"""
\(jclassDecl)
private static let \(caseName)_ctor: JavaMethodID = {
  guard let mid = \(caseName)_javaClass.getMethodID(name: "<init>", sig: "\(ctorSig)") else {
    fatalError("Could not find \(caseClass).<init>\(ctorSig)")
  }
  return mid
}()
"""
      }.joined(separator: "\n")
    }
    else {
        caseJClassDecls = ""
    }

    return
"""
\(expandJavaClassDeclDefault(in: context))
\(caseJClassDecls)
"""
  }

  func expandJavaObjectDecls(in context: some MacroExpansionContext) throws -> String {
    if isSerialized {
      return try expandJavaObjectDeclsAsSerializedCases(in: context)
    }
    if withAssociatedValues {
      return try expandJavaObjectDeclsAsClass(in: context)
    } else {
      return try expandJavaObjectDeclsAsEnum(in: context)
    }
  }

  /// Which case a serialized peer holds is its Java class, so the inbound
  /// conversion asks JNI directly rather than reading a discriminator field.
  /// Nothing is added to the peer's surface for the sake of the question.
  func expandJavaObjectDeclsAsSerializedCases(in context: some MacroExpansionContext) throws -> String {
    let branches = try caseDecls().map { c -> String in
      let caseName = c.name.text
      guard !c.parameters.isEmpty else {
        return
"""
  if jni.IsInstanceOf(obj, Self.\(caseName)_javaClass.ptr) != 0 {
    return .\(caseName)
  }
"""
      }

      let reads = try c.parameters.map { p -> String in
        let getter = try c.serializedGetterName(of: p)
        // The case is reconstructed by calling it, so a labelled payload has
        // to be passed by label — an unlabelled one must not be.
        let label = p.passedName.map { "\($0): " } ?? ""
        guard let wrapped = p.type.as(OptionalTypeSyntax.self)?.wrappedType else {
          return label + "__o.call(method: \"\(getter)\")"
        }
        return label
          + "__o.callObjectMethod(method: \"\(getter)\", sig: \"()\(try p.type.jniSignature(primitivesAsObjects: true))\", [])"
          + ".map { \(wrapped.trimmedDescription).fromJavaObject($0) }"
      }.joined(separator: ",\n      ")

      return
"""
  if jni.IsInstanceOf(obj, Self.\(caseName)_javaClass.ptr) != 0 {
    return .\(caseName)(
      \(reads)
    )
  }
"""
    }.joined(separator: "\n")

    return
"""
public static func fromJavaObject(_ obj: JavaObject?) -> Self {
  guard let obj else {
    fatalError("\(typeName).fromJavaObject received null")
  }
  let __o = JObject(obj)
\(branches)
  fatalError("\(typeName).fromJavaObject received an object of no known case")
}

public func toJavaObject() -> JavaObject? {
  \(expandToJavaObject(in: context))
}
"""
  }

  func expandCtorDecls(in context: some MacroExpansionContext) throws -> String {
    // A serialized case carries its payload in Java fields, so there is no
    // allocation to make from Java and no address to free.
    if isSerialized { return "" }
    if withAssociatedValues {
      let caseCtors = try caseDecls().map {
        try $0.makeBridgingDecls(typeDecl: self)
      }.joined(separator: "\n")

      return
"""
\(try expandCtorDeclsAsClass(in: context))

\(caseCtors)
"""

    } else {
      return ""
    }
  }

  func expandToJavaObject(in context: some MacroExpansionContext) -> String {
    let fqn = fqn(from: context)
    let toJavaCases = caseDecls().map { c in
      let caseName = c.name.text
      let caseFqn = fqn + "$" + caseName
      let caseJClass = "Self.\(caseName)_javaClass"

      // A payload-free case is a Kotlin `object` either way: one instance,
      // reached through INSTANCE, with nothing to copy.
      if !c.parameters.isEmpty && isSerialized {
        let bindings = (0..<c.parameters.count).map { "let __v\($0)" }.joined(separator: ", ")
        let args = c.parameters.enumerated().map { i, p in
          p.type.is(OptionalTypeSyntax.self)
            ? "JavaParameter(object: __v\(i).toJavaObject())"
            : "__v\(i).toJavaParameter()"
        }.joined(separator: ", ")

        return
"""
case .\(caseName)(\(bindings)):
  let __jvmFramePushed = jni.PushLocalFrame(\(c.parameters.count + 4)) >= 0
  let __jvmPeer = \(caseJClass).create(ctor: Self.\(caseName)_ctor, [\(args)])
  guard __jvmFramePushed else { return __jvmPeer }
  return jni.PopLocalFrame(__jvmPeer)
"""
      }

      if c.parameters.isEmpty {
        return
"""
case .\(caseName):
  return \(caseJClass).getStatic(field: "INSTANCE", sig: "L\(caseFqn);")
"""
      } else {
        return
"""
case .\(caseName):
  let ptr = UnsafeMutablePointer<\(typeName)>.allocate(capacity: 1)
  ptr.initialize(to: self)
  return \(caseJClass).callStaticObjectMethod(method: Self.\(caseName)_fromPtr, [Int(bitPattern: ptr).toJavaParameter()])
"""
      }
    }.joined(separator: "\n")

    return
"""
switch self {
  \(toJavaCases)
}
"""
  }

  func expandRegisterNatives(in context: some MacroExpansionContext, parents: [any TypeDeclSyntax], namespacePath: [String]) throws -> String {
    // A serialized peer declares no natives at all, so there is no batch to
    // register and no __nativeBytes field to write.
    guard withAssociatedValues, !isSerialized else { return "" }
    return try expandRegisterNativesDefault(in: context, parents: parents, namespacePath: namespacePath)
  }

  func expandCreateNativeMethods(parents: [any TypeDeclSyntax], namespacePath: [String]) throws -> [String] {
    // Simple enums (no associated values) are bridged as Java enum constants
    // (INSTANCE / ordinal), not pointer-backed. They have no deinit_jni and
    // no init/var/func natives — return nothing so callers don't emit a stale
    // RegisterNatives block referencing a non-existent `Type.deinit_jni`.
    guard withAssociatedValues, !isSerialized else { return [] }

    let fqn = fqn(with: parents)

    let caseNatives = try caseDecls().flatMap { c in
      let caseJavaName = c.name.text + "Impl"
      let caseJniSig = try c.jniSignature()
      let caseFn = "\(fqn).\(c.jniName)"

      let caseCtorNatives = expandCreateNativeMethod(name: caseJavaName, sig: caseJniSig, fn: caseFn)

      let caseParamNatives = try c.parameters.map{ p in
        let paramJavaName =  try "get" + c.name.text.capitalized + p.name.capitalized  + "Impl"
        let paramJniSig = "(J)\(try p.type.jniSignature())"
        let paramFn = "\(fqn).\(try c.jniName(of: p))"

        return expandCreateNativeMethod(name: paramJavaName, sig: paramJniSig, fn: paramFn)
      }

      return [caseCtorNatives] + caseParamNatives
    }

    return try expandCreateNativeMethodsDefault(parents: parents, namespacePath: namespacePath) + caseNatives
  }

  func expandJavaObjectDeclsAsEnum(in context: some MacroExpansionContext) throws -> String {
    // Resolve the Java enum constant via the static `valueOf(String)` method.
    //
    // This used to be attributed to an ART quirk — GetStaticFieldID throwing
    // NoSuchFieldError for an enum constant that reflection could plainly see.
    // It was not a quirk: `JNI.GetStaticFieldID` dispatched to `GetFieldID`,
    // which is *correct* to throw NoSuchFieldError when asked for a static
    // field. That is fixed, so the field route would work now.
    //
    // `valueOf` stays because it is symmetric with `fromJavaObject` (which maps
    // by ordinal) and needs no field ids. `values()[i]` would also work;
    // `valueOf(name)` is simplest and avoids array handling.
    let enumSig = fqn(from: context)
    let toJavaCases = cases().map{
"""
case .\($0): return Self.javaClass.callStaticObjectMethod(method: Self.__valueOf__, ["\($0)".toJavaParameter()])
"""
    }.joined(separator: "\n")

    let valueOfDecl =
"""
private static let __valueOf__: JavaMethodID = {
  guard let mid = javaClass.getStaticMethodID(name: "valueOf", sig: "(Ljava/lang/String;)L\(enumSig);") else {
    fatalError("Could not find \(enumSig).valueOf")
  }
  return mid
}()
"""

    let fromJavaCases = cases().enumerated().map{
"""
case \($0.offset): return .\($0.element)
"""
    }.joined(separator: "\n")

    return
"""
\(valueOfDecl)

public static func fromJavaObject(_ obj: JavaObject?) -> \(typeName) {
  let ordinal: Int32 = JObject(obj!).call(method: "ordinal")
  switch ordinal {
  \(fromJavaCases)
  default:
  fatalError("Cannot create an enum case")
  }
}

public func toJavaObject() -> JavaObject? {
  switch self {
  \(toJavaCases)
  }
}

"""
  }


}

