import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


/// `@jvmBinding` — generate a TYPED swift4j binding for a foreign value type
/// (one declared in another module, e.g. CRLogging's `SourceInfo`) WITHOUT
/// editing its source. Attach to an `extension <Foreign>` in your own module
/// that provides a manually-specified forwarding factory `makeForJVM(...)`:
///
///     @jvmBinding
///     extension SourceInfo {
///         static func makeForJVM(instanceId: Int64, type: String) -> SourceInfo {
///             SourceInfo(instanceId: instanceId, type: type)
///         }
///     }
///
/// Member macro: injects the pointer-box witnesses (`toJavaObject`/`fromJavaObject`/
/// `_self`/`javaClass`/deinit), an `init0_jni` thunk that calls the factory, and a
/// `<Foreign>_class_init` register-natives entry (a `static func` with
/// `@_silgen_name`, since an extension has no name for a `@_cdecl` peer).
///
/// You declare `: JObjectConvertible` on the extension yourself (an extension-
/// attached macro can't add a conformance — `'extension' macro cannot be attached
/// to extension`), and gate the extension `#if os(Android)` (the witnesses are
/// JNI-only). The macro is syntactic and can't introspect the foreign type's real
/// `init` (different module), so the factory's signature is the *manually
/// specified* surface it binds. See jvm_foreign_binding.md.
public struct JvmBindingMacro {
  static let factoryName = "makeForJVM"
}


// MARK: - MemberMacro (pointer-box witnesses + init0 + class_init)

extension JvmBindingMacro: MemberMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingMembersOf declaration: some DeclGroupSyntax,
                               conformingTo protocols: [TypeSyntax],
                               in context: some MacroExpansionContext) throws -> [DeclSyntax] {

    guard let ext = declaration.as(ExtensionDeclSyntax.self) else {
      throw JvmMacrosError.message("@jvmBinding must be attached to an extension of the foreign type.")
    }
    let typeName = ext.extendedType.trimmed.description

    guard let factory = ext.memberBlock.members.lazy.compactMap({
            $0.decl.as(FunctionDeclSyntax.self)
          }).first(where: { $0.name.text == factoryName && $0.isStatic }) else {
      throw JvmMacrosError.message(
        "@jvmBinding requires a `static func \(factoryName)(...) -> \(typeName)` "
        + "forwarding factory in the extension (the manually-specified initializer).")
    }

    let module = moduleName(of: node, in: context)
    let fqn = (module.map { "\($0)/" } ?? "") + typeName

    let box = boxDecls(typeName: typeName, fqn: fqn)
    let initThunk = try initThunkDecls(typeName: typeName, factory: factory)
    let initSig = try "(\(factory.signature.jniSignatures().joined()))J"
    let classInit = classInitDecl(typeName: typeName, module: module, initSig: initSig)

    return ["\(raw: box)\n\(raw: initThunk)\n\(raw: classInit)"]
  }

  /// Field-independent pointer-box conformance witnesses (need only the type
  /// name + Java FQN).
  static func boxDecls(typeName: String, fqn: String) -> String {
"""
private enum __JClass__ {
  static let name = "\(fqn)"
  static let shared = {
    guard let cls = JClass(fqn: javaName) else {
      fatalError("Could not find \\(javaName) class")
    }
    return cls
  } ()
}
public nonisolated static var javaName: String { __JClass__.name }
public nonisolated static var javaClass: JClass { __JClass__.shared }
private static func _self(_ obj: JavaObject?) -> UnsafeMutablePointer<\(typeName)> {
  let ptr: JavaLong = JObject(obj!).call(method: "_ptr")
  return _self(ptr)
}
private static func _self(_ ptr: JavaLong) -> UnsafeMutablePointer<\(typeName)> {
  return UnsafeMutablePointer<\(typeName)>(bitPattern: Int(truncatingIfNeeded: ptr))!
}
public static func fromJavaObject<R>(_ obj: JavaObject?, closure: (UnsafeMutablePointer<\(typeName)>) -> R) -> R {
  return closure(_self(obj))
}
public static func fromJavaObject(_ obj: JavaObject?) -> Self {
  return _self(obj).pointee
}
public func toJavaObject() -> JavaObject? {
  let ptr = UnsafeMutablePointer<\(typeName)>.allocate(capacity: 1)
  ptr.initialize(to: self)
  return \(typeName).javaClass.callStaticObjectMethod(method: "fromPtr", sig: "(J)L\(fqn);", Int(bitPattern: ptr))
}
fileprivate typealias deinit_jni_t = @convention(c)(UnsafeMutablePointer<JNIEnv>, JavaClass?, JavaLong) -> Void
fileprivate static let deinit_jni: deinit_jni_t = { _, _, ptr in
  guard let p = UnsafeMutablePointer<\(typeName)>(bitPattern: Int(ptr)) else { return }
  p.deinitialize(count: 1)
  p.deallocate()
}
"""
  }

  /// `init0_jni` thunk: maps JNI params and calls the manually-specified factory.
  static func initThunkDecls(typeName: String, factory: FunctionDeclSyntax) throws -> String {
    let paramTypes = try ["UnsafeMutablePointer<JNIEnv>", "JavaClass?"] + factory.signature.jniTypes()
    let closureParams = try ["_", "_"] + factory.signature.jniParams()
    let mapping = try factory.signature.paramsMapping()

    let body =
"""
  \(mapping.stmts.joined(separator: "\n  "))
  let ptr = UnsafeMutablePointer<\(typeName)>.allocate(capacity: 1)
  ptr.initialize(to: \(typeName).\(factoryName)(\(mapping.mapped)))
  return JavaLong(Int(bitPattern: ptr))
"""

    return
"""
fileprivate typealias init0_jni_t = @convention(c)(\(paramTypes.joined(separator: ", "))) -> JavaLong
fileprivate static let init0_jni: init0_jni_t = {\(closureParams.joined(separator: ", ")) in
\(mapping.post == nil ? body : mapping.post!(body))
}
"""
  }

  /// `<Type>_class_init` register-natives entry. A `static func` with
  /// `@_silgen_name` (not a `@_cdecl` peer — the attached extension has no name
  /// for a `suffixed(_class_init)` peer). The JNI symbol is keyed off module +
  /// foreign type, matching the CLI-generated native.
  static func classInitDecl(typeName: String, module: String?, initSig: String) -> String {
    let jniType = typeName.replacingOccurrences(of: "_", with: "_1")
    let pkg = (module.map { [$0.replacingOccurrences(of: "_", with: "_1")] } ?? [])
    let fqnEsc = (pkg + [jniType]).joined(separator: "_")
    let symbol = "Java_\(fqnEsc)_\(jniType)_1class_1init"
    return
"""
@_silgen_name("\(symbol)")
public static func \(typeName)_class_init(_ env: UnsafeMutablePointer<JNIEnv>, _ cls: JavaClass?) {
  guard let cls = cls else { return }
  let natives = [
    JNINativeMethod2(name: "init0", sig: "\(initSig)", fn: unsafeBitCast(\(typeName).init0_jni, to: UnsafeMutableRawPointer.self)),
    JNINativeMethod2(name: "deinit", sig: "(J)V", fn: unsafeBitCast(\(typeName).deinit_jni, to: UnsafeMutableRawPointer.self))
  ]
  let _ = jni.RegisterNatives(cls, natives)
}
"""
  }

  /// Swift module name from the attachment site's `#fileID` (`Module/File.swift`).
  static func moduleName(of node: some SyntaxProtocol, in context: some MacroExpansionContext) -> String? {
    guard let segments = context.location(of: node)?.file.as(StringLiteralExprSyntax.self)?.segments,
          segments.count == 1, case .stringSegment(let seg)? = segments.first,
          let slash = seg.content.text.firstIndex(of: "/") else { return nil }
    return String(seg.content.text[seg.content.text.startIndex ..< slash])
  }
}
