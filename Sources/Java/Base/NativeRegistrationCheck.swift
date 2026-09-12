import CJNI


/// Cross-checks a generated peer's `native` declarations against the set the
/// macro actually registered.
///
/// The two sides derive this set independently and share no code. The swift4j
/// CLI reads the whole file set, so it sees extensions; a peer macro sees only
/// the declaration it is attached to, so it cannot. Nothing forces the results
/// to agree, and no compiler can see a disagreement — `RegisterNatives` binds
/// by name and descriptor *string*, at runtime.
///
/// The two directions fail differently, which is why they are reported
/// differently:
///
/// - **Registered, not declared.** `RegisterNatives` rejects the whole batch,
///   so *every* native on the class is left unbound and the first call to any
///   of them throws `UnsatisfiedLinkError` — with a message naming a method
///   that is very likely not the one that caused it. Fatal, and already fatal
///   before this check existed; the check only supplies the name.
///
/// - **Declared, not registered.** The batch succeeds. That one method is
///   unbound and throws `UnsatisfiedLinkError` if it is ever called, which may
///   be never. Reported as a warning rather than a trap, because it does not
///   break a class that works today, and promoting it would turn dead
///   generated code into a startup crash.
public enum NativeRegistrationCheck {

  /// Whether to run the reflection cross-check when `RegisterNatives` reports
  /// success. A failure is always diagnosed regardless.
  ///
  /// Default on. The declared-but-unregistered direction is invisible without
  /// it, since that batch succeeds. The cost is one `getDeclaredMethods` plus a
  /// few calls per method, once per class at class-load — against a failure
  /// mode that surfaces as a crash with a misleading name at an arbitrary later
  /// point.
  ///
  /// Setting this has to happen before any `@jvm` class loads, which in
  /// practice means before the first JNI call into the library.
  public nonisolated(unsafe) static var isEnabled = true

  /// Every warning raised so far, in the order the classes loaded.
  ///
  /// `System.err` is where a human reads these; this is where a test does. The
  /// fatal direction is deliberately absent — it traps, so there is nothing
  /// left to inspect.
  public nonisolated(unsafe) private(set) static var findings: [String] = []

  /// Called by the generated `<Type>_class_init` immediately after
  /// `RegisterNatives`.
  public static func check(class cls: JavaClass,
                           named className: String,
                           registered: [JNINativeMethod2],
                           registerResult: JavaInt) {
    var didFail = registerResult != 0
    if jni.ExceptionCheck() {
      didFail = true
      jni.ExceptionDescribe()
      jni.ExceptionClear()
    }

    guard didFail || isEnabled else { return }

    let declared = declaredNatives(of: cls)
    // `Set` unqualified resolves to the generated `java.util.Set` peer here.
    let declaredKeys = Swift.Set(declared.map { $0.key })
    let registeredKeys = Swift.Set(registered.map { "\($0.name)\($0.sig)" })

    let notDeclared = registered.filter { !declaredKeys.contains("\($0.name)\($0.sig)") }
    let notRegistered = declared.filter { !registeredKeys.contains($0.key) }

    if !notRegistered.isEmpty {
      var message = "swift4j: \(className) declares native methods that nothing registers.\n"
      message += "Each throws UnsatisfiedLinkError if it is ever called.\n"
      message += "A peer macro cannot see its type's extensions, so an extension-declared\n"
      message += "member is the usual cause; mark it @nonjvm or move it into the type body.\n"
      for entry in notRegistered {
        message += "  \(entry.name)\(entry.descriptor)\n    \(entry.display)\n"
      }
      warn(message)
    }

    guard !notDeclared.isEmpty else {
      if didFail {
        // Nothing in our list is missing from the peer, so the batch was
        // rejected for a reason this check does not model. Say so rather than
        // implying the lists agree and all is well.
        fatalError("""
          swift4j: RegisterNatives failed for \(className) (result \(registerResult)), \
          but every native it registered is declared by the peer with a matching \
          descriptor. Check the JNI exception above.
          """)
      }
      return
    }

    var message = "swift4j: \(className) registered native methods its Java peer does not declare.\n"
    message += "RegisterNatives rejects the whole batch on any one of these, so every native\n"
    message += "on this class is unbound and the first call to any of them throws\n"
    message += "UnsatisfiedLinkError — naming a method that is probably not the cause.\n"
    for entry in notDeclared {
      message += "  registered: \(entry.name)\(entry.sig)\n"
      let sameName = declared.filter { $0.name == entry.name }
      if sameName.isEmpty {
        message += "    peer declares no native by that name\n"
      } else {
        for candidate in sameName {
          message += "    peer declares: \(candidate.name)\(candidate.descriptor)\n"
        }
      }
    }
    fatalError(message)
  }

  /// Every declared constructor, rendered the way Java prints it.
  ///
  /// A serialized peer's constructor descriptor is computed by the macro from
  /// the Swift declaration and emitted by the CLI from its own member list. When
  /// those disagree the only symptom is `getMethodID` returning nil, so the
  /// expected descriptor alone does not say what went wrong. The actual
  /// constructor does.
  public static func describeConstructors(of cls: JavaClass) -> String {
    guard let ctorsArray = callObject(cls, "getDeclaredConstructors", "()[Ljava/lang/reflect/Constructor;"),
          let ctorClass = jni.FindClass("java/lang/reflect/Constructor"),
          let toString = jni.GetMethodID(ctorClass, "toString", "()Ljava/lang/String;") else {
      return "  (could not reflect the peer's constructors)"
    }
    defer { jni.DeleteLocalRef(ctorsArray) }

    var lines: [String] = []
    for index in 0 ..< jni.GetArrayLength(ctorsArray) {
      guard let ctor = jni.GetObjectArrayElement(ctorsArray, index) else { continue }
      defer { jni.DeleteLocalRef(ctor) }
      guard let text = jni.CallObjectMethod(ctor, toString, []) else { continue }
      defer { jni.DeleteLocalRef(text) }
      lines.append("  peer declares: \(String.fromJavaObject(text))")
    }
    return lines.isEmpty ? "  (the peer declares no constructors)" : lines.joined(separator: "\n")
  }
}


private extension NativeRegistrationCheck {

  struct DeclaredNative {
    let name: String
    let descriptor: String
    /// `java.lang.reflect.Method.toString()` — modifiers and Java type names,
    /// which reads better than a descriptor when a human has to act on it.
    let display: String

    var key: String { "\(name)\(descriptor)" }
  }

  /// `Modifier.NATIVE`.
  static var nativeModifier: JavaInt { 0x0100 }

  static func declaredNatives(of cls: JavaClass) -> [DeclaredNative] {
    guard let methodsArray = callObject(cls, "getDeclaredMethods", "()[Ljava/lang/reflect/Method;"),
          let methodClass = jni.FindClass("java/lang/reflect/Method"),
          let getName = jni.GetMethodID(methodClass, "getName", "()Ljava/lang/String;"),
          let getModifiers = jni.GetMethodID(methodClass, "getModifiers", "()I"),
          let getParameterTypes = jni.GetMethodID(methodClass, "getParameterTypes", "()[Ljava/lang/Class;"),
          let getReturnType = jni.GetMethodID(methodClass, "getReturnType", "()Ljava/lang/Class;"),
          let toString = jni.GetMethodID(methodClass, "toString", "()Ljava/lang/String;") else {
      return []
    }
    defer { jni.DeleteLocalRef(methodsArray) }

    var result: [DeclaredNative] = []
    for index in 0 ..< jni.GetArrayLength(methodsArray) {
      guard let method = jni.GetObjectArrayElement(methodsArray, index) else { continue }
      defer { jni.DeleteLocalRef(method) }

      guard jni.CallIntMethod(method, getModifiers, []) & nativeModifier != 0 else { continue }

      guard let nameObj = jni.CallObjectMethod(method, getName, []) else { continue }
      defer { jni.DeleteLocalRef(nameObj) }
      let name = String.fromJavaObject(nameObj)

      // `<Type>_class_init` is the one native that is deliberately absent from
      // the registered set: it binds by exported symbol name (@_cdecl /
      // @_silgen_name), which is what makes it callable before anything has
      // been registered. It is not evidence of a disagreement.
      guard !name.hasSuffix("_class_init") else { continue }

      var parameters = ""
      if let paramArray = jni.CallObjectMethod(method, getParameterTypes, []) {
        defer { jni.DeleteLocalRef(paramArray) }
        for paramIndex in 0 ..< jni.GetArrayLength(paramArray) {
          guard let param = jni.GetObjectArrayElement(paramArray, paramIndex) else { continue }
          defer { jni.DeleteLocalRef(param) }
          parameters += descriptor(ofClass: param)
        }
      }

      var returns = "V"
      if let returnType = jni.CallObjectMethod(method, getReturnType, []) {
        defer { jni.DeleteLocalRef(returnType) }
        returns = descriptor(ofClass: returnType)
      }

      var display = name
      if let text = jni.CallObjectMethod(method, toString, []) {
        defer { jni.DeleteLocalRef(text) }
        display = String.fromJavaObject(text)
      }

      result.append(DeclaredNative(name: name,
                                   descriptor: "(\(parameters))\(returns)",
                                   display: display))
    }
    return result
  }

  /// JVM descriptor for a `java.lang.Class`, via `getName()`.
  static func descriptor(ofClass cls: JavaObject) -> String {
    guard let classClass = jni.FindClass("java/lang/Class"),
          let getName = jni.GetMethodID(classClass, "getName", "()Ljava/lang/String;"),
          let nameObj = jni.CallObjectMethod(cls, getName, []) else {
      return "?"
    }
    defer { jni.DeleteLocalRef(nameObj) }
    return descriptor(forClassNamed: String.fromJavaObject(nameObj))
  }

  static func descriptor(forClassNamed name: String) -> String {
    switch name {
    case "int": return "I"
    case "long": return "J"
    case "double": return "D"
    case "float": return "F"
    case "boolean": return "Z"
    case "byte": return "B"
    case "char": return "C"
    case "short": return "S"
    case "void": return "V"
    default:
      // `Class.getName()` already yields descriptor form for arrays, apart from
      // the package separator: "[Ljava.lang.String;", "[[I". A plain class name
      // needs wrapping.
      let binary = String(name.map { $0 == "." ? "/" : $0 })
      return name.hasPrefix("[") ? binary : "L\(binary);"
    }
  }

  static func callObject(_ obj: JavaObject, _ method: String, _ sig: String) -> JavaObject? {
    guard let classClass = jni.FindClass("java/lang/Class"),
          let mid = jni.GetMethodID(classClass, method, sig) else { return nil }
    return jni.CallObjectMethod(obj, mid, [])
  }

  /// Routed through `System.err` rather than Swift's `print`, which on Android
  /// goes to a stdout nothing is reading. `System.err` reaches logcat there and
  /// stderr on a desktop JVM.
  static func warn(_ message: String) {
    findings.append(message)
    guard let stream = systemErr,
          let printStream = jni.FindClass("java/io/PrintStream"),
          let println = jni.GetMethodID(printStream, "println", "(Ljava/lang/String;)V"),
          let text = jni.NewStringUTF(message) else { return }
    defer { jni.DeleteLocalRef(text) }
    jni.CallVoidMethod(stream, println, [JavaParameter(object: text)])
  }

  static let systemErr: JavaObject? = {
    guard let system = jni.FindClass("java/lang/System"),
          let field = jni.GetStaticFieldID(system, "err", "Ljava/io/PrintStream;"),
          let stream = jni.GetStaticObjectField(system, field) else { return nil }
    return jni.NewGlobalRef(stream)
  } ()
}
