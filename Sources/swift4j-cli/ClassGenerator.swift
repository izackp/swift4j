import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class ClassGenerator<T: TypeDeclSyntax>: TypeGenerator<T> {
  private var varGens: [VarGenerator] = []
  private var methodGens: [MethodGenerator] = []

  private var ctorGens: [CtorGenerator] {
    typeDecl.exportedInitializers.map { CtorGenerator($0, className: name) }
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && node.parentDecl?.isExported ?? true {
      varGens.append(VarGenerator(node,
                                  className: name,
                                  observationTracking: typeDecl.isObservable,
                                  registry: settings.registry))
    }
    return .skipChildren
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && node.parentDecl?.isExported ?? true
       && node.isBridgeable(typeConformsToHashable: typeDecl.conformsToHashable) {
      methodGens.append(MethodGenerator(node, className: name))
    }
    return .skipChildren
  }
}


extension ClassGenerator: TypeGeneratorProtocol {
  func generate(with ctx: inout Context) -> TypeProxy {
    var failableCount = 0
    let ctors = ctorGens.enumerated().map { (index, gen) -> String in
      var failableOrdinal: Int? = nil
      if gen.isFailable {
        failableOrdinal = failableCount
        failableCount += 1
      }
      return gen.generate(with: &ctx, index: index, failableOrdinal: failableOrdinal)
    }.joined(separator: "\n\n")

    var class_init =
"""
  static {
    \((registryParents.first ?? typeDecl).typeName).class_init();
  }
"""

    if !nested {
      class_init +=
"""

  private static void class_init() {
    if(!class_initialized) {
      \(name)_class_init();
      class_initialized = true;
    }
  }
  private static boolean class_initialized = false;
  private static native void \(name)_class_init();
"""
    }

    // When the Swift type conforms to `Error` / `LocalizedError`, emit the
    // Java class as a Throwable subtype so JNI throws land as a typed
    // exception on the Kotlin side.
    //
    // For Kotlin's `t.message` to surface the Swift description, override
    // `getMessage()` to delegate to whichever Swift accessor the type
    // happens to provide:
    //   - `var message: String` → swift4j already emits `getMessage()`, no override
    //   - `var description: String` → call `getDescriptionImpl(_ptr())`
    //   - `var errorDescription: String?` → call `getErrorDescriptionImpl(_ptr())`
    //   - none → no override, inherit Throwable default (null)
    let isError = typeDecl.conformsToError
    let extendsClause = isError ? " extends Exception" : ""
    let varNames: Set<String> = isError
      ? Set(typeDecl.exportedDecls.varDecls.flatMap { $0.decls.map { $0.name } })
      : []
    let errorBridging: String
    if isError && !varNames.contains("message") {
      if varNames.contains("description") {
        errorBridging =
"""

  @Override
  public String getMessage() {
    return this.getDescriptionImpl(_ptr());
  }
"""
      } else if varNames.contains("errorDescription") {
        errorBridging =
"""

  @Override
  public String getMessage() {
    return this.getErrorDescriptionImpl(_ptr());
  }
"""
      } else {
        errorBridging = ""
      }
    } else {
      errorBridging = ""
    }

    // When the Swift type conforms to `Hashable` (on its main decl), emit
    // Object.equals/hashCode overrides delegating into the synthesized Swift
    // thunks (see swift4j macro `expandHashableDecls`). Two bridged instances
    // are equal iff Swift `==` says so; hashCode mirrors Swift `hashValue`.
    let hashableBridging = typeDecl.conformsToHashable ?
"""

  @Override
  public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof \(name))) return false;
    return equalsImpl(_ptr(), ((\(name)) o)._ptr());
  }

  @Override
  public int hashCode() {
    return hashCodeImpl(_ptr());
  }

  private native boolean equalsImpl(long ptr, long otherPtr);
  private native int hashCodeImpl(long ptr);
""" : ""

    let valueTypeBridging = typeDecl is StructDeclSyntax ?
"""

  /**
   * An independent owned copy. Edits to the result do not affect this instance,
   * matching what `var x = y` does for the underlying Swift value type.
   */
  public \(name) copy() {
    return fromPtr(copyImpl(_ptr()));
  }

  private native long copyImpl(long ptr);

  /**
   * Wraps an address owned by something else: no deinit is registered, so
   * nothing here frees or copies the value. Valid only while the owner keeps
   * the storage alive, which is what the unsafeWith* scopes bracket.
   */
  private static \(name) fromUnownedPtr(long ptr) {
    return new \(name)(new SwiftPtr(ptr));
  }
""" : ""

    let source =
"""
public \(nested ? "static" : "") class \(name)\(extendsClause) {

\(class_init)

  private final SwiftPtr _ptr;

  private long _ptr() {
    return _ptr.get();
  }

  private static \(name) fromPtr(long ptr) {
    return new \(name)(new SwiftPtr(ptr, \(name)::deinit));
  }

  private static native void deinit(long ptr);
\(valueTypeBridging)

  private \(name)(SwiftPtr ptr) {
    _ptr = ptr;
  }
\(errorBridging)
\(hashableBridging)
\(ctors)

\(varGens.map{$0.generate(with: &ctx)}.joined(separator: "\n\n"))

\(methodGens.map{$0.generate(with: &ctx)}.joined(separator: "\n\n"))

\(nestedTypeGens.compactMap {
    let proxy = $0.generate(with: &ctx)
    guard proxy is JavaTypeProxy else { return nil }
    return $0.generate(with: &ctx).source
  }
  .joined(separator: "\n\n")
)
}
"""
    return JavaTypeProxy(name: name, namespacePath: nested ? [] : namespacePath, source: source)
  }
}
