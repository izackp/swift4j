import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class VarGenerator {
  typealias Context = ProxyGenerator.Context

  private let varDecl: VariableDeclSyntax
  private let className: String
  private let observationTracking: Bool
  private let registry: TypeRegistry?

  private var modifiers: String {
    varDecl.isStatic ? "static" : ""
  }

  private var callee: String {
    varDecl.isStatic ? className : "this"
  }

  init(_ varDecl: VariableDeclSyntax,
       className: String,
       observationTracking: Bool = false,
       registry: TypeRegistry? = nil) {
    self.varDecl = varDecl
    self.className = className
    self.observationTracking = observationTracking
    self.registry = registry
  }

  func generate(with ctx: inout Context) -> String {
    return varDecl.decls.map {
"""
\(generateGetter(from: $0, with: &ctx))
\($0.readonly ? "" : generateSetter(from: $0, with: &ctx))
\($0.observable(varDecl) && observationTracking ? generateGetterWithObservationTracking(from: $0, with: &ctx) : "")
\(generateScopedBorrow(from: $0, with: &ctx))
"""
    }.joined(separator: "\n")
  }

  /// Mirrors `VariableDeclSyntax.scopedBorrowable` on the macro side. The macro
  /// registers `unsafeWith<X>Impl` for exactly this set, so the native must be
  /// *declared* for exactly this set too — `RegisterNatives` fails the whole
  /// batch on a missing method (R2). Deliberately over-broad; see below.
  /// Must stay identical to `IdentifierTypeSyntax.isPrimitive` in the macro
  /// module, plus the two types whose peers are immutable Java values.
  static let nonBorrowableNames: Set<String> = [
    "Void", "Bool", "Int", "Int64", "Int32", "Int16", "Int8",
    "UInt", "UInt64", "UInt32", "UInt16", "UInt8",
    "Float", "Double", "String", "Data"
  ]

  static func scopedBorrowable(_ decl: VariableDeclSyntax.VarDecl, isStatic: Bool) -> Bool {
    guard !isStatic, !decl.readonly, !decl.computed else { return false }

    if let ident = decl.type.as(IdentifierTypeSyntax.self) {
      return !nonBorrowableNames.contains(ident.name.text)
    }
    return decl.type.is(MemberTypeSyntax.self)
  }

  private func scopedBorrowable(_ decl: VariableDeclSyntax.VarDecl) -> Bool {
    return Self.scopedBorrowable(decl, isStatic: varDecl.isStatic)
  }

  /// Whether a *public* `unsafeWith<X>` wrapper is worth exposing — true only
  /// where the property's type is a `@jvm` struct, so the borrow is a real
  /// view rather than a converted copy.
  ///
  /// This is the half the macro cannot decide: it sees `Foo` as bare syntax,
  /// while the CLI has indexed every `@jvm` declaration across all input files.
  /// Types that bridge by conversion (`Date` -> `java.util.Date`, `URL`)
  /// therefore get the native declared but no caller.
  private func exposesScopedBorrow(_ decl: VariableDeclSyntax.VarDecl) -> Bool {
    guard scopedBorrowable(decl), let registry else { return false }

    if let ident = decl.type.as(IdentifierTypeSyntax.self) {
      return registry.topLevelType(named: ident.name.text)?.is(StructDeclSyntax.self) ?? false
    }
    if let member = decl.type.as(MemberTypeSyntax.self) {
      let leaf = member.name.text
      let base = member.baseType.as(IdentifierTypeSyntax.self)?.name.text
      if let base, registry.hasNamespacedType(name: leaf, under: [base]) {
        return true
      }
      return registry.topLevelType(named: leaf)?.is(StructDeclSyntax.self) ?? false
    }
    return false
  }

  /// Whether any of this declaration's names gets a public `unsafeWith` — and
  /// therefore whether the owning class needs the `_inScope` flag.
  var exposesAnyScopedBorrow: Bool {
    varDecl.decls.contains(where: exposesScopedBorrow)
  }

  private func generateScopedBorrow(from decl: VariableDeclSyntax.VarDecl, with ctx: inout Context) -> String {
    guard scopedBorrowable(decl) else { return "" }

    let name = "unsafeWith\(decl.capitalizedName)"
    let nativeDecl = "  private native void \(name)Impl(long ptr, io.scade.swift4j.SwiftBorrow body);"

    guard exposesScopedBorrow(decl) else { return nativeDecl }

    let borrowedType = decl.type.map(with: &ctx)
    return
"""
  /**
   * Runs {@code body} against a view of this property, in place: no copy is
   * made and writes through the view are writes into this instance.
   *
   * <p>Unsafe because the view is only valid until {@code body} returns. It is
   * invalidated on the way out, so keeping it and using it later throws rather
   * than reading freed memory — but the pointer it wrapped is gone either way.
   * Use {@link #\(name.replacingOccurrences(of: "unsafeWith", with: "get"))()} for a value you can keep.
   *
   * <p>The scope holds this peer's monitor for its whole duration, since it
   * hands out an interior pointer into this instance and a concurrent write
   * would corrupt it. Keep {@code body} to small reads and writes: taking a
   * Java lock inside it can deadlock against a thread blocked on this peer.
   */
  public void \(name)(io.scade.swift4j.SwiftBorrow<\(borrowedType).Borrowed> body) {
    synchronized (_ptr) {
      // Reentrant monitors would let a nested scope on this same peer succeed,
      // producing two live views of one storage. That is a caller bug, and a
      // deterministic one, so it is worth naming.
      if (_inScope) {
        throw new IllegalStateException(
          "\(className).\(name) is already in a scope on this instance");
      }
      _inScope = true;
      final \(borrowedType).Borrowed[] scope = new \(borrowedType).Borrowed[1];
      try {
        \(callee).\(name)Impl(_ptr(), raw -> {
          scope[0] = \(borrowedType).wrapBorrowed((\(borrowedType)) raw);
          body.with(scope[0]);
        });
      } finally {
        if (scope[0] != null) {
          scope[0].invalidate();
        }
        _inScope = false;
      }
    }
  }

\(nativeDecl)
"""
  }

  /// Forwarding accessors for the nested `Borrowed` view. Statics are skipped:
  /// a borrow is of an instance.
  func generateForwarding(with ctx: inout Context) -> String {
    guard !varDecl.isStatic else { return "" }

    return varDecl.decls.map { decl -> String in
      let type = decl.type.map(with: &ctx)
      let getter =
"""
    public \(type) get\(decl.capitalizedName)() {
      return view().get\(decl.capitalizedName)();
    }
"""
      guard !decl.readonly else { return getter }
      return getter + "\n" +
"""
    public void set\(decl.capitalizedName)(\(type) value) {
      view().set\(decl.capitalizedName)(value);
    }
"""
    }.joined(separator: "\n")
  }

  private func generateGetter(from decl: VariableDeclSyntax.VarDecl, with ctx: inout Context) -> String {
    let name = "get\(decl.capitalizedName)"
    let retType = decl.type.map(with: &ctx)

    let implParam: String,
        implParamDecl: String

    if varDecl.isStatic {
      implParam = ""
      implParamDecl = ""

    } else {
      implParam = "_ptr()"
      implParamDecl = "long ptr"
    }

    let call = PeerLock.guarded("return \(callee).\(name)Impl(\(implParam));",
                                locked: !varDecl.isStatic)

    return
"""
  public \(modifiers) \(retType) \(name)() {
\(call)
  }
  private \(modifiers) native \(retType) \(name)Impl(\(implParamDecl));
"""
  }

  private func generateSetter(from decl: VariableDeclSyntax.VarDecl, with ctx: inout Context) -> String {
    let name = "set\(decl.capitalizedName)"
    let valType = decl.type.map(with: &ctx)

    let implParam: String,
        implParamDecl: String

    if varDecl.isStatic {
      implParam = "value"
      implParamDecl = "\(valType) value"

    } else {
      implParam = "_ptr(), value"
      implParamDecl = "long ptr, \(valType) value"
    }

    let call = PeerLock.guarded("\(callee).\(name)Impl(\(implParam));",
                                locked: !varDecl.isStatic)

    return
"""
  public \(modifiers) void \(name)(\(valType) value) {
\(call)
  }
  private \(modifiers) native void \(name)Impl(\(implParamDecl));
"""
  }

  private func generateGetterWithObservationTracking(from decl: VariableDeclSyntax.VarDecl, with ctx: inout Context) -> String {
    let name = "get\(decl.capitalizedName)WithObservationTracking"
    let retType = decl.type.map(with: &ctx)

    // `onChange` fires later, from the observation machinery, not inside this
    // call — so guarding the read does not put user code under the monitor.
    let call = PeerLock.guarded("return \(callee).\(name)Impl(_ptr(), onChange);", locked: true)

    return
"""
  public \(retType) \(name)(java.lang.Runnable onChange) {
\(call)
  }
  private native \(retType) \(name)Impl(long ptr, java.lang.Runnable onChange);
"""
  }
}

