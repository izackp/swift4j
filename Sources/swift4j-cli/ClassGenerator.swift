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

  /// Shared by both peer shapes. A serialized peer still registers natives —
  /// statics keep theirs — and even with none, `_class_init` must exist on the
  /// Java side because the macro emits the peer that calls it unconditionally.
  private var classInitBlock: String {
    var block =
"""
  static {
    \((registryParents.first ?? typeDecl).typeName).class_init();
  }
"""
    if !nested {
      block +=
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
    return block
  }

  /// A peer that carries copied fields instead of a `SwiftPtr`.
  ///
  /// Everything that exists only to own or borrow an address is gone: no
  /// `_ptr`, no `deinit`, no `copy()`, no `Borrowed`, no `unsafeWith*`, no
  /// cache, and no setters. The public getter names and return types are
  /// unchanged, which is the point — a consumer reading `getFirstName()` does
  /// not learn that the object stopped being a handle.
  ///
  /// What survives is statics. A static has no receiver to have been
  /// marshalled, so it stays native-backed exactly as before. Instance methods
  /// do not survive: there is no pointer to dispatch on, and the macro drops
  /// their natives from the same `isSerialized` check, so the registered set
  /// stays in agreement.
  private func generateSerialized(with ctx: inout Context) -> TypeProxy {
    let instanceVars = varGens.filter { !$0.isStatic }
    let staticVars = varGens.filter { $0.isStatic }
    let staticMethods = methodGens.filter { $0.isStatic }

    let fields = instanceVars.map { $0.serializedFieldDecls(with: &ctx) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    let ctorParams = instanceVars.flatMap { $0.serializedCtorParams(with: &ctx) }
    let assignments = instanceVars.flatMap { $0.serializedAssignments() }
    let comparisons = instanceVars.flatMap { $0.serializedFieldComparisons(with: &ctx) }
    let fieldNames = comparisons.map { $0.name }

    // Called by the macro's `toJavaObject`, so it must be public and its
    // parameter order must match declaration order on both sides.
    let ctor =
"""
  public \(name)(\(ctorParams.joined(separator: ", "))) {
\(assignments.joined(separator: "\n"))
  }
"""

    let accessors = instanceVars.map { $0.generateSerialized(with: &ctx) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    let staticMembers = (staticVars.map { $0.generate(with: &ctx) }
                         + staticMethods.map { $0.generate(with: &ctx) })
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    // Real value equality, which a pointer-backed peer could not offer. Two
    // snapshots of the same row taken either side of an unrelated write are
    // equal here and were two distinct objects before.
    let equality = fieldNames.isEmpty ? "" :
"""

  @Override
  public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof \(name))) return false;
    \(name) other = (\(name)) o;
    return \(comparisons.map { $0.expression }.joined(separator: "\n        && "));
  }

  @Override
  public int hashCode() {
    return java.util.Objects.hash(\(fieldNames.joined(separator: ", ")));
  }
"""

    let nestedSources = nestedTypeGens.compactMap { gen -> String? in
      let proxy = gen.generate(with: &ctx)
      guard proxy is JavaTypeProxy else { return nil }
      return proxy.source
    }.joined(separator: "\n\n")

    let source =
"""
public \(nested ? "static" : "") class \(name) {

\(classInitBlock)

\(fields)

\(ctor)

\(accessors)
\(equality)
\(staticMembers)

\(nestedSources)
}
"""

    return JavaTypeProxy(name: name,
                         namespacePath: namespacePath,
                         needsSwiftPtr: false,
                         source: source)
  }

  func generate(with ctx: inout Context) -> TypeProxy {
    if typeDecl.isSerialized {
      return generateSerialized(with: &ctx)
    }
    // Only a type that hands out a scope needs the flag, and only such a type
    // can be re-entered while one is open.
    let hasScope = varGens.contains { $0.exposesAnyScopedBorrow }

    // Caching is for value peers only. A class peer's object is owned by Swift
    // and can be mutated with no bridge involvement, so there is no point at
    // which its cache could be invalidated.
    let isValue = typeDecl is StructDeclSyntax
    let cacheNames = isValue ? varGens.flatMap { $0.cacheableNames } : []
    var cacheSlots: [String: Int] = [:]
    for (index, name) in cacheNames.enumerated() {
      cacheSlots[name] = index
    }

    var failableCount = 0
    let ctors = ctorGens.enumerated().map { (index, gen) -> String in
      var failableOrdinal: Int? = nil
      if gen.isFailable {
        failableOrdinal = failableCount
        failableCount += 1
      }
      return gen.generate(with: &ctx, index: index, failableOrdinal: failableOrdinal)
    }.joined(separator: "\n\n")

    let class_init = classInitBlock

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
    let implementsClause = cacheNames.isEmpty ? "" : " implements io.scade.swift4j.SwiftCacheOwner"
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

    // The child half: a cached peer knows where it is held, so a write into it
    // clears the entry rather than leaving a value Swift never saw to be read
    // back as though the write had landed.
    let cacheChild = isValue ?
"""

  private io.scade.swift4j.SwiftCacheOwner _cacheOwner;
  private int _cacheSlot;

  /** Internal: called by an owner when it caches this peer. */
  public void _attachCache(io.scade.swift4j.SwiftCacheOwner owner, int slot) {
    _cacheOwner = owner;
    _cacheSlot = slot;
  }

  /**
   * Drops this peer from whatever cached it. Called before any write, so a
   * cache can only ever accelerate reads that agree with Swift.
   */
  private void _detachCache() {
    io.scade.swift4j.SwiftCacheOwner owner = _cacheOwner;
    if (owner != null) {
      _cacheOwner = null;
      owner._invalidateCacheSlot(_cacheSlot);
    }
  }
""" : ""

    let cacheFields = cacheNames.isEmpty ? "" :
"""

\(varGens.map { $0.cacheFieldDecls(with: &ctx) }.filter { !$0.isEmpty }.joined(separator: "\n"))

  @Override
  public void _invalidateCacheSlot(int slot) {
    switch (slot) {
\(cacheNames.enumerated().map { (index, name) in
    "      case \(index): _cache\(name.prefix(1).uppercased())\(name.dropFirst()) = null; break;"
  }.joined(separator: "\n"))
      default: break;
    }
  }
"""

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
public \(nested ? "static" : "") class \(name)\(extendsClause)\(implementsClause) {

\(class_init)

  private final SwiftPtr _ptr;
\(hasScope ? "  private boolean _inScope;\n" : "")
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
\(cacheChild)\(cacheFields)
\(borrowedClass)
\(ctors)

\(varGens.map{$0.generate(with: &ctx, sealed: hasScope, cacheSlots: cacheSlots, cacheable: isValue)}.joined(separator: "\n\n"))

\(methodGens.map{$0.generate(with: &ctx, sealed: hasScope, cacheable: isValue)}.joined(separator: "\n\n"))

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
