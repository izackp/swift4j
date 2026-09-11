import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


extension IdentifierTypeSyntax: MappableTypeSyntax {
  func map(with ctx: inout ProxyGenerator.Context, primitivesAsObjects: Bool) -> String {
    let mappedTypeName = Self.map(name: name.text, with: &ctx, primitivesAsObjects: primitivesAsObjects)

    if let genericArgs = genericArgumentClause?.arguments, !genericArgs.isEmpty {
      let mappedGenericArgs = genericArgs.map{ $0.argument.map(with: &ctx, primitivesAsObjects: true) }
      return "\(mappedTypeName)<\(mappedGenericArgs.joined(separator: ", "))>"
    } else {
      return mappedTypeName
    }

  }

  private static func map(name: String, with ctx: inout ProxyGenerator.Context, primitivesAsObjects: Bool) -> String {
    switch name {
        // Primitives
      case "Bool": primitivesAsObjects ? "Boolean" : "boolean"
      // Unsigned types share the signed Java primitive (same JNI wire format);
      // Unsigned+JConvertible range-checks on conversion. Mirrors the macro side.
      case "Int", "Int64", "UInt", "UInt64": primitivesAsObjects ? "Long" : "long"
      case "Int32", "UInt32": primitivesAsObjects ? "Integer" : "int"
      case "Int16", "UInt16": primitivesAsObjects ? "Short" : "short"
      case "Int8", "UInt8": primitivesAsObjects ? "Byte" : "byte"
      case "Float": primitivesAsObjects ? "Float" : "float"
      case "Double": primitivesAsObjects ? "Double" : "double"

        // Standard
      case "Void": "void"
      case "String": "String"

      case "Error": {
        ctx.imports.insert("io.scade.swift4j.SwiftError")
        return "SwiftError"
      }()

        // Foundation
      case "Date": {
        ctx.imports.insert("java.util.Date")
        return "Date"
      }()
      case "URL": {
        ctx.imports.insert("java.net.URL")
        return "URL"
      }()
      case "Data": "byte[]"
      case "Result": {
        ctx.imports.insert("io.scade.swift4j.Result")
        return "Result"
      }()
      // Swift.Hasher bridges to the @jvm SwiftHasher wrapper (a reference-backed
      // box around Swift.Hasher). The macro side resolves the JNI descriptor via
      // `Hasher.javaName` at runtime; here we emit the Java proxy class name.
      case "Hasher": "SwiftHasher"

      default: resolveValueType(name: name, with: &ctx)
            ?? resolveExternal(name: name, with: &ctx)
            ?? name
    }
  }

  /// Looks the type up in the `--value-type` map: a Swift type declared to
  /// bridge as a Java value rather than a pointer-backed peer, which is what
  /// the `Date`/`Data`/`URL` cases above do for the types swift4j ships
  /// knowledge of. Registers an import for the qualified name and returns the
  /// unqualified one, matching how those cases behave.
  ///
  /// Consulted only from `default:`, so the built-in mappings win and
  /// `String`, `Int`, and friends cannot be redefined out from under the
  /// generator.
  private static func resolveValueType(name: String, with ctx: inout ProxyGenerator.Context) -> String? {
    guard let fqn = ctx.settings.valueTypes[name] else { return nil }
    guard let shortName = fqn.split(separator: ".").last.map(String.init) else { return nil }
    if shortName != fqn {
      ctx.imports.insert(fqn)
    }
    return shortName
  }

  /// Looks up the type in the per-invocation external-package map (populated
  /// from `--external-type Name=java.package`). On hit, registers an import
  /// for the qualified name and returns the unqualified name; on miss returns
  /// nil so the caller falls back to emitting the bare identifier.
  private static func resolveExternal(name: String, with ctx: inout ProxyGenerator.Context) -> String? {
    guard let pkg = ctx.settings.externalPackages[name] else { return nil }
    if pkg == ctx.package { return name }
    ctx.imports.insert("\(pkg).\(name)")
    return name
  }
}
