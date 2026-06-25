import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions

class EnumGenerator: TypeGenerator<EnumDeclSyntax> { }


extension EnumGenerator: TypeGeneratorProtocol {
  var isRefType: Bool { return false }

  func generate(with ctx: inout ProxyGenerator.Context) -> TypeProxy {
    return typeDecl.withAssociatedValues
      ? generateSealedClass(with: &ctx)
      : generateEnum(with: &ctx)
  }

  func generateSealedClass(with ctx: inout ProxyGenerator.Context) -> TypeProxy {
    let nestedJava = nestedJavaSources(with: &ctx)
    let nestedBlock = nestedJava.isEmpty ? "" : "\n\n\(nestedJava)"

    return KotlinTypeProxy(name: name, source:
"""
sealed class \(name)(protected val ptr: SwiftPtr) {
  private companion object {
      val class_initialized: Boolean
      init {
          \(name)_class_init()
          class_initialized = true
      }

      @JvmStatic
      external fun \(name)_class_init()

      @JvmStatic
      external fun deinit(ptr: Long)

\(
  typeDecl.caseDecls().map{
    $0.generateCaseExtCtor(with: &ctx)
  }.joined(separator: "\n\n")
)

\(
  typeDecl.caseDecls().flatMap { c in
    c.parameters.map { p in
      p.generateExtGetter(with: &ctx, for: c.jvmName)
    }
  }.joined(separator: "\n\n")
)
  }

  // Must be named `_ptr` (not `ptr`): the Swift side resolves the native
  // pointer via JObject.call(method: "_ptr") in `_self` (see JvmValueTypeDeclSyntax
  // / ClassDeclSyntax). Pointer-backed classes already expose `_ptr()` from the
  // class generator; associated-value enums used `ptr()` here, so fromJavaObject
  // (Kotlin→Swift) crashed with NoSuchMethod "_ptr". Keep the names aligned.
  private fun _ptr(): Long {
      return ptr.get()
  }

\(typeDecl.caseDecls().map{$0.generateCaseType(with: &ctx, in: typeDecl.typeName)}.joined(separator: "\n\n"))\(nestedBlock)
}
"""
    )
  }

  func generateEnum(with ctx: inout ProxyGenerator.Context) -> TypeProxy {
    let nestedJava = nestedJavaSources(with: &ctx)

    if nestedJava.isEmpty {
      return JavaTypeProxy(name: name, namespacePath: nested ? [] : namespacePath, source:
"""
public enum \(name) {
  \(typeDecl.cases().joined(separator: ", "));
}
"""
      )
    }

    // When the enum has nested @jvm types, emit the JNI class_init
    // scaffolding so nested types can reference it from their static block.
    return JavaTypeProxy(name: name, namespacePath: nested ? [] : namespacePath, source:
"""
public enum \(name) {
  \(typeDecl.cases().joined(separator: ", "));

  static {
    class_init();
  }
  private static void class_init() {
    if(!class_initialized) {
      \(name)_class_init();
      class_initialized = true;
    }
  }
  private static boolean class_initialized = false;
  private static native void \(name)_class_init();

\(nestedJava)
}
"""
    )
  }

  private func nestedJavaSources(with ctx: inout ProxyGenerator.Context) -> String {
    return nestedTypeGens.compactMap { gen in
      let proxy = gen.generate(with: &ctx)
      guard proxy is JavaTypeProxy else { return nil }
      return proxy.source
    }.joined(separator: "\n\n")
  }
}


// Kotlin hard keywords — illegal as bare identifiers, but legal when
// backtick-escaped (`object`, `null`, ...). Enum case names map directly to
// Kotlin nested class / object names, so any keyword case must be escaped.
fileprivate let kotlinHardKeywords: Set<String> = [
  "as", "break", "class", "continue", "do", "else", "false", "for", "fun",
  "if", "in", "interface", "is", "null", "object", "package", "return",
  "super", "this", "throw", "true", "try", "typealias", "typeof", "val",
  "var", "when", "while"
]

fileprivate extension EnumCaseElementSyntax {
  var jvmName: String { name.text }
  var jvmExtCtorName: String { jvmName + "Impl" }
  // Backtick-escaped name for use as a Kotlin identifier (class/object/type).
  var kotlinName: String {
    kotlinHardKeywords.contains(jvmName) ? "`\(jvmName)`" : jvmName
  }

  func generateCaseExtCtor(with ctx: inout ProxyGenerator.Context) -> String {
    let paramDecls = ctx.with(language: .kotlin) { ctx in
      paramsMapping(with: &ctx).map{ "\($0.name): \($0.type)" }.joined(separator: ", ")
    }

    return
"""
      @JvmStatic
      external fun \(jvmExtCtorName)(\(paramDecls)): Long
"""
  }

  func generateCaseType(with ctx: inout ProxyGenerator.Context, in enumName: String) -> String {
    if parameters.isEmpty {
      return
"""
  object \(kotlinName) : \(enumName)(SwiftPtr(\(jvmExtCtorName)()))
"""
    }

    let paramsMapping = ctx.with(language: .kotlin) { self.paramsMapping(with: &$0) }

    let params = paramsMapping.map{ $0.name }.joined(separator: ", ")
    let paramDecls = paramsMapping.map{ "\($0.name): \($0.type)" }.joined(separator: ", ")

    return
"""
  class \(kotlinName) internal constructor(ptr: SwiftPtr): \(enumName)(ptr) {
\(parameters.map{$0.generateGetter(with: &ctx, for: jvmName)}.joined(separator: "\n\n"))

    constructor(\(paramDecls)): this(SwiftPtr(\(jvmExtCtorName)(\(params)), \(enumName)::deinit))

    private companion object {
      @JvmStatic
      fun fromPtr(ptr: Long): \(kotlinName) {
        return \(kotlinName)(SwiftPtr(ptr, \(enumName)::deinit))
      }
    }
  }
"""
  }
}


fileprivate extension ParameterSyntax {
  func extGetterName(name: String, in enumCaseName: String) -> String {
    "get\(enumCaseName.capitalized)\(name.capitalized)Impl"
  }

  func generateGetter(with ctx: inout ProxyGenerator.Context, for enumCaseName: String) -> String {
    let mapping = ctx.with(language: .kotlin){ map(with: &$0) }
    return
"""
    val \(mapping.name): \(mapping.type)
      get() = \(extGetterName(name: mapping.name, in: enumCaseName))(ptr.get())
"""
  }
  
  func generateExtGetter(with ctx: inout ProxyGenerator.Context, for enumCaseName: String) -> String {
    let mapping = ctx.with(language: .kotlin){ map(with: &$0) }

    return
"""
      @JvmStatic
      external fun \(extGetterName(name: mapping.name, in: enumCaseName))(ptr: Long): \(mapping.type)
"""
  }
}
