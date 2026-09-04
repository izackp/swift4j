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
    // Only a type that hands out a scope needs the flag, and only such a type
    // can be re-entered while one is open.
    let hasScope = varGens.contains { $0.exposesAnyScopedBorrow }

    // Only value types get projections; a class peer already refers to one
    // Swift object, so its getters already propagate.
    let isValue = typeDecl is StructDeclSyntax

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
\(PeerLock.guarded("return this.getDescriptionImpl(_ptr());", locked: true))
  }
"""
      } else if varNames.contains("errorDescription") {
        errorBridging =
"""

  @Override
  public String getMessage() {
\(PeerLock.guarded("return this.getErrorDescriptionImpl(_ptr());", locked: true))
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
    // The receiver goes through its scope; the argument materialises via
    // _ptr(). Scoping both would be one fewer copy, but two projections of the
    // same owner — `box.getLeaf().equals(box.getLeaf())` — would then open that
    // owner's scope twice and hit the nesting guard, which is right to refuse.
    // One copy per comparison, and none when neither side is projected.
    // The argument is materialised *before* the receiver's scope opens. Doing
    // it inside would re-enter the same owner when both project from it, and
    // the nesting guard is right to refuse that.
    let hashableProjection = isValue ?
"""
    if (_projected()) {
      final long other = ((\(name)) o)._ptr();
      return _through(v -> v.equalsImpl(v._ptr(), other));
    }
""" : ""

    let hashCodeProjection = isValue ?
"""
    if (_projected()) {
      return _through(v -> v.hashCode());
    }

""" : ""

    let hashableBridging = typeDecl.conformsToHashable ?
"""

  @Override
  public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof \(name))) return false;
\(hashableProjection)    return equalsImpl(_ptr(), ((\(name)) o)._ptr());
  }

  @Override
  public int hashCode() {
\(hashCodeProjection)    return hashCodeImpl(_ptr());
  }

  private native boolean equalsImpl(long ptr, long otherPtr);
  private native int hashCodeImpl(long ptr);
""" : ""

    // A projection owns no storage. It re-enters its owner for every operation,
    // so `box.getLeaf().setLabel(x)` writes into `box` rather than into a copy
    // that is discarded at the end of the expression.
    //
    let projectionFields = isValue ?
"""

  private final io.scade.swift4j.SwiftScope _scope;

  /**
   * Held only to keep a materialised copy alive across a call into Swift. See
   * {@link #_ptr()}: a projection has no stable address of its own, so passing
   * one as a parameter has to produce a real box, and that box must outlive the
   * JNI call that reads it.
   */
  private \(name) _materialised;
""" : ""

    let projectionPtr = isValue ?
"""
    if (_ptr == null) {
      // Materialise a fresh copy. Fresh rather than cached, because the owner
      // may have changed since the last call and a stale box would be worse
      // than the copy this exists to avoid.
      final \(name)[] copy = new \(name)[1];
      _scope.open(raw -> copy[0] = ((\(name)) raw).copy());
      _materialised = copy[0];
      return _materialised._ptr.get();
    }

""" : ""

    let projectionCtor = isValue ?
"""

  private \(name)(io.scade.swift4j.SwiftScope scope) {
    _ptr = null;
    _scope = scope;
  }

  /** Internal: builds a peer that reads and writes through {@code scope}. */
  public static \(name) projection(io.scade.swift4j.SwiftScope scope) {
    return new \(name)(scope);
  }

  private boolean _projected() {
    return _ptr == null;
  }

  /**
   * Runs {@code body} against a live view of whatever this projects, and
   * returns what the body produced. Every projected operation goes through
   * here, so each is its own scope and nothing holds a pointer between them.
   */
  private <R> R _through(java.util.function.Function<\(name), R> body) {
    final Object[] result = new Object[1];
    _scope.open(raw -> result[0] = body.apply((\(name)) raw));
    @SuppressWarnings("unchecked")
    R typed = (R) result[0];
    return typed;
  }
""" : ""

    let valueTypeBridging = typeDecl is StructDeclSyntax ?
"""

  /**
   * An independent owned copy. Edits to the result do not affect this instance,
   * matching what `var x = y` does for the underlying Swift value type.
   */
  public \(name) copy() {
    // Through the scope, not _ptr(). Materialising would copy to get an
    // address and then copy that — two copies to produce one.
    if (_projected()) {
      return _through(v -> v.copy());
    }
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

    // A distinct type for what unsafeWith hands out, so a borrow cannot be
    // stored in a field of the owning type by accident — `Leaf x = it` does
    // not compile, and declaring a `Leaf.Borrowed` field is a deliberate,
    // greppable act. Deliberately NOT a subclass: that would be assignable to
    // the base type and defeat the whole point.
    //
    // It forwards to a real peer rather than holding a pointer, so it needs no
    // natives of its own and the registered set is unchanged. The validity flag
    // lives here rather than in SwiftPtr, which keeps the check off `_ptr()`
    // and therefore off the read hot path entirely.
    let borrowedClass = typeDecl is StructDeclSyntax ?
"""

  /**
   * A view of a {@link \(name)} that is only valid for the duration of the
   * unsafeWith* call that produced it.
   *
   * <p>Using one after its scope ends throws instead of reading freed memory.
   * That check is the difference between an IllegalStateException naming the
   * offending line and a SIGSEGV inside swift_retain.
   */
  public static final class Borrowed {
    private final \(name) _view;
    private volatile boolean _valid = true;

    private Borrowed(\(name) view) {
      _view = view;
    }

    /** Internal: called by the owner on the way out of its unsafeWith scope. */
    public void invalidate() {
      _valid = false;
    }

    private \(name) view() {
      if (!_valid) {
        throw new IllegalStateException(
          "\(name).Borrowed used outside the unsafeWith scope that created it");
      }
      return _view;
    }

\(varGens.map { $0.generateForwarding(with: &ctx) }.filter { !$0.isEmpty }.joined(separator: "\n"))

\(methodGens.compactMap { $0.generateForwarding(with: &ctx) }.joined(separator: "\n"))
  }

  /** Internal: wraps a scoped view. Called by the owner's unsafeWith wrapper. */
  public static Borrowed wrapBorrowed(\(name) view) {
    return new Borrowed(view);
  }
""" : ""

    let source =
"""
public \(nested ? "static" : "") class \(name)\(extendsClause) {

\(class_init)

  private final SwiftPtr _ptr;
\(hasScope ? "  private boolean _inScope;\n" : "")\(projectionFields)
  private long _ptr() {
\(projectionPtr)    return _ptr.get();
  }

  private static \(name) fromPtr(long ptr) {
    return new \(name)(new SwiftPtr(ptr, \(name)::deinit));
  }

  private static native void deinit(long ptr);
\(valueTypeBridging)

  private \(name)(SwiftPtr ptr) {
    _ptr = ptr;\(isValue ? "\n    _scope = null;" : "")
  }
\(projectionCtor)\(errorBridging)
\(hashableBridging)
\(borrowedClass)
\(ctors)

\(varGens.map{$0.generate(with: &ctx, sealed: hasScope, projectable: isValue)}.joined(separator: "\n\n"))

\(methodGens.map{$0.generate(with: &ctx, sealed: hasScope, projectable: isValue)}.joined(separator: "\n\n"))

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
