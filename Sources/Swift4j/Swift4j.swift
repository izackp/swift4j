@_exported import Java

public enum Platform: Equatable {
    case macOS
    case Linux
    case Windows
    case Android
}

#if os(Android)

@attached(extension,
          conformances: JObjectConvertible, JvmPointerBoxed,
          names: named(toJavaObject), named(fromJavaObject))
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
public macro jvm() =
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

#else

// Non-Android: stub macros. JVM bridging members aren't generated; iOS/macOS
// consumers see the annotated types as plain Swift declarations.
@attached(peer)
public macro jvm() =
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
