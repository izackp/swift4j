@_exported import Java

public enum Platform: Equatable {
    case macOS
    case Linux
    case Windows
    case Android
}

#if os(Android)

@attached(extension,
          conformances: JObjectConvertible,
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
public macro nonjvm() =
  #externalMacro(module: "Swift4jMacros", type: "NoOpPeerMacro")

#endif
