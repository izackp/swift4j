@_exported import Java

public enum Platform: Equatable {
    case macOS
    case Linux
    case Windows
    case Android
}

#if os(Android)

@attached(extension,
          conformances: JObjectConvertible, JvmPointerBoxed, JObjectUpdatable,
          names: named(toJavaObject), named(fromJavaObject), named(updateJavaObject))
@attached(peer,
          names: suffixed(_class_init))
@attached(member,
          names:
            named(jobj),
            named(javaClass),
            named(deinit_jni_t),
            named(deinit_jni),
            arbitrary)
@attached(memberAttribute)
public macro jvm(serialized: Bool = false, nativeBytes: Int = 0) =
  #externalMacro(module: "Swift4jMacros", type: "JvmMacro")


@attached(peer,
          names: arbitrary)
public macro jvm_exported() =
  #externalMacro(module: "Swift4jMacros", type: "JvmExportedMacro")

/// Generate a TYPED swift4j binding for a foreign (third-party / other-module)
/// type WITHOUT editing its source. Attach to an `extension <Foreign>` in your
/// own module that provides a manually-specified forwarding factory the macro
/// reads to bind the initializer:
///
///     @jvmBinding
///     extension SourceInfo {
///         static func makeForJVM(instanceId: Int64, type: String) -> SourceInfo {
///             SourceInfo(instanceId: instanceId, type: type)
///         }
///     }
///
/// You declare `: JObjectConvertible` on the extension and gate the whole thing
/// `#if os(Android)` (the bridge witnesses are JNI-only). The macro injects the
/// pointer-box witnesses, an `init0_jni` thunk calling the factory, and the
/// `<Foreign>_class_init` register-natives entry. The CLI emits the typed Kotlin
/// peer. See jvm_foreign_binding.md + JvmBindingMacro.
@attached(member, names: arbitrary)
public macro jvmBinding() =
  #externalMacro(module: "Swift4jMacros", type: "JvmBindingMacro")

@attached(peer)
public macro nonjvm() =
  #externalMacro(module: "Swift4jMacros", type: "NonjvmMacro")

/// Marshal a stored property whose own type cannot cross, by naming the type
/// that can and the two conversions between them.
///
/// `@nonjvm` is not an alternative on a `@jvm(serialized:)` type. A serialized
/// value's representation *is* its marshalled stored properties, so opting one
/// out does not hide a detail — it removes part of the value from the wire, and
/// whatever is left cannot rebuild it.
///
/// `uuid_t` is the case that forced this. It is a tuple, and a tuple is
/// non-nominal, so it can conform to nothing — not `Codable`, not
/// `LosslessStringConvertible`, not anything a generator could key off. The
/// conversion has to be supplied:
///
///     @jvm(as: String.self,
///          toJava: { (u: uuid_t) in UUID(uuid: u).uuidString.lowercased() },
///          toSwift: { (s: String) in UUID(uuidString: s)!.uuid })
///     public private(set) var uuid: uuid_t
///
/// Both are ordinary closures, so the compiler checks them — a conversion with
/// the wrong shape is a build error rather than a value that crosses wrong.
///
/// Read from the declaration by both the macro and the CLI. That is the point
/// of putting it here rather than inferring it from a conformance: the macro
/// sees one file, and a conformance can be declared in any of them.
@attached(peer)
public macro jvm<Value, Raw>(as: Raw.Type,
                             toJava: (Value) -> Raw,
                             toSwift: (Raw) throws -> Value) =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

#else

// Non-Android: stub macros. JVM bridging members aren't generated; iOS/macOS
// consumers see the annotated types as plain Swift declarations.
@attached(peer)
public macro jvm(serialized: Bool = false, nativeBytes: Int = 0) =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

@attached(peer)
public macro jvm<Value, Raw>(as: Raw.Type,
                             toJava: (Value) -> Raw,
                             toSwift: (Raw) throws -> Value) =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

@attached(peer)
public macro jvm_exported() =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

@attached(peer)
public macro jvmBinding() =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

@attached(peer)
public macro nonjvm() =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

#endif
