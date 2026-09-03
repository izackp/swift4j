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
  private static let nonBorrowableNames: Set<String> = [
    "Void", "Bool", "Int", "Int64", "Int32", "Int16", "Int8",
    "UInt", "UInt64", "UInt32", "UInt16", "UInt8",
    "Float", "Double", "String", "Data"
  ]

  private func scopedBorrowable(_ decl: VariableDeclSyntax.VarDecl) -> Bool {
    guard !varDecl.isStatic, !decl.readonly, !decl.computed else { return false }

    if let ident = decl.type.as(IdentifierTypeSyntax.self) {
      return !Self.nonBorrowableNames.contains(ident.name.text)
    }
    return decl.type.is(MemberTypeSyntax.self)
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
   * <p>Unsafe because the view is only valid until {@code body} returns.
   * Storing it, or using it after the call, reads memory that may have been
   * freed or reused. Use {@link #\(name.replacingOccurrences(of: "unsafeWith", with: "get"))()} for a value you can keep.
   */
  public void \(name)(io.scade.swift4j.SwiftBorrow<\(borrowedType)> body) {
    \(callee).\(name)Impl(_ptr(), body);
  }

\(nativeDecl)
"""
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

    return
"""
  public \(modifiers) \(retType) \(name)() {
    return \(callee).\(name)Impl(\(implParam));
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

    return
"""
  public \(modifiers) void \(name)(\(valType) value) {
    \(callee).\(name)Impl(\(implParam));
  }
  private \(modifiers) native void \(name)Impl(\(implParamDecl));
"""
  }

  private func generateGetterWithObservationTracking(from decl: VariableDeclSyntax.VarDecl, with ctx: inout Context) -> String {
    let name = "get\(decl.capitalizedName)WithObservationTracking"
    let retType = decl.type.map(with: &ctx)

    return
"""
  public \(retType) \(name)(java.lang.Runnable onChange) {
    return \(callee).\(name)Impl(_ptr(), onChange);
  }
  private native \(retType) \(name)Impl(long ptr, java.lang.Runnable onChange);
"""
  }
}

