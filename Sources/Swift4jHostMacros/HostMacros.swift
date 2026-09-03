@_exported import Java

/// The `@jvm` family, declared without the `#if os(Android)` gate that
/// `Swift4j` puts around it.
///
/// `Swift4j` gates the real macros so iOS and macOS consumers get no-op stubs
/// and no JNI code. A `#if` is resolved when the module declaring it compiles,
/// so a `.define` on a *consumer* target cannot lift that gate — a fixture
/// target built against `Swift4j` silently gets stubs and type-checks nothing.
///
/// This module exists so `Swift4jFixtures` can compile the real expansions on
/// the host. Test-only: nothing ships against it.
///
/// The attribute lists below must mirror `Swift4j.swift`. Drift shows up as a
/// build failure in `Swift4jFixtures`, which is the point of having it.

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

@attached(member, names: arbitrary)
public macro jvmBinding() =
  #externalMacro(module: "Swift4jMacros", type: "JvmBindingMacro")

@attached(peer)
public macro nonjvm() =
  #externalMacro(module: "Swift4jMacros", type: "NonjvmMacro")
