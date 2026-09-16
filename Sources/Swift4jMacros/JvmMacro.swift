import Foundation

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


public struct JvmMacro {
  static func typeDecl(from decl: some DeclSyntaxProtocol) throws -> any JvmTypeDeclSyntax {
    if let classDecl = decl.as(ClassDeclSyntax.self) {
      return classDecl

    } else if let structDecl = decl.as(StructDeclSyntax.self) {
      return structDecl

    } else if let enumDecl = decl.as(EnumDeclSyntax.self) {
      return enumDecl

    } else {
      throw JvmMacrosError.message("@jvm macro can only be applied to a class, struct or enum declaration")
    }
  }

  /// `isSerialized` lives on `TypeDeclSyntax`; the macro entry points receive
  /// a `DeclGroupSyntax`, so it has to be reached through the concrete case.
  static func isSerialized(_ declaration: some DeclGroupSyntax) -> Bool {
    if let decl = declaration.as(StructDeclSyntax.self) { return decl.isSerialized }
    if let decl = declaration.as(ClassDeclSyntax.self) { return decl.isSerialized }
    if let decl = declaration.as(EnumDeclSyntax.self) { return decl.isSerialized }
    return false
  }

  /// Same reach-through for the mutation gate. Structs only: the sole call site
  /// tests `isStruct` first.
  static func supportsMutation(_ declaration: some DeclGroupSyntax) -> Bool {
    if let decl = declaration.as(StructDeclSyntax.self) { return decl.serializedSupportsMutation }
    return false
  }

  /// `serialized:` means "copy the value across instead of handing out a
  /// pointer", which only makes sense for a value type with fields.
  ///
  /// On a **class** it would silently destroy identity: two peers for the same
  /// Swift object would compare equal, and a write through one would reach a
  /// copy rather than the object. On an **enum** it is silently ignored —
  /// EnumGenerator has its own peer shape, so the attribute would read as
  /// applied while changing nothing.
  ///
  /// Both are quiet failures, so they are rejected at expansion instead.
  static func assertSerializedIsApplicable(_ declaration: some DeclGroupSyntax) throws {
    guard isSerialized(declaration) else { return }

    if declaration.is(ClassDeclSyntax.self) {
      throw JvmMacrosError.message(
        "@jvm(serialized:) cannot be applied to a class. Serializing copies the "
        + "value across the boundary, which would discard the reference identity "
        + "a class has by definition: two peers for the same object would compare "
        + "equal, and a write through one would not reach the other.")
    }

    if declaration.is(EnumDeclSyntax.self) {
      throw JvmMacrosError.message(
        "@jvm(serialized:) is not supported on an enum. Enums generate a "
        + "different peer shape, so the attribute would be silently ignored.")
    }
  }

  /// A stored binding with no type annotation is dropped by `decls`, so it
  /// reaches neither the peer's field list, nor the constructor, nor
  /// `updateJavaObject`. Where the author also hand-writes the conversions the
  /// build stays green and the field is simply gone.
  static func assertSerializedStoredPropertiesAreVisible(_ declaration: some DeclGroupSyntax) throws {
    guard isSerialized(declaration) else { return }

    for member in declaration.memberBlock.members {
      guard let decl = member.decl.as(VariableDeclSyntax.self), !decl.isStatic else { continue }

      let storedBindings = decl.bindings.filter { $0.accessorBlock == nil }
      guard !storedBindings.isEmpty, decl.decls.count != storedBindings.count else { continue }

      let unannotated = storedBindings
        .filter { $0.typeAnnotation == nil }
        .map { $0.pattern.trimmedDescription }

      let subject = unannotated.isEmpty
        ? "A stored property of '\(decl.bindings.trimmedDescription)'"
        : "Stored propert\(unannotated.count == 1 ? "y" : "ies") \(unannotated.map { "'\($0)'" }.joined(separator: ", "))"

      throw JvmMacrosError.message(
        "\(subject) on a @jvm(serialized:) type has no type annotation, so it "
        + "cannot be copied into the Java peer and would be silently absent from "
        + "the peer's fields, its constructor and updateJavaObject. Write the "
        + "type explicitly, e.g. `var count: Int = 0`.")
    }
  }

  /// `hasDeclaredMarshalling` decides on the presence of an `as:` label;
  /// `jvmMarshalling` additionally requires a simple metatype expression and
  /// both conversions. Where they disagree the author's conversions are
  /// discarded without a word.
  static func assertDeclaredMarshallingIsUsable(_ declaration: some DeclGroupSyntax) throws {
    for member in declaration.memberBlock.members {
      guard let decl = member.decl.as(VariableDeclSyntax.self),
            let reason = decl.jvmMarshallingDefect else { continue }

      throw JvmMacrosError.message(
        "@jvm(as:toJava:toSwift:) on '\(decl.bindings.trimmedDescription)' is "
        + "declared but cannot be used: \(reason). The conversions would be "
        + "discarded and the property would cross as its Swift type.")
    }
  }

  static func assert(context: some MacroExpansionContext) throws {
    if let enclosingDeclType = context.enclosingDeclType {
      if !enclosingDeclType.isExported {
        throw JvmMacrosError.message(
          "Enclosing type '\(enclosingDeclType.typeName)' is not exported. Add the @jvm attribute to the parent."
        )
      }
    }
  }

  static func addPlatformConditions(_ node: SwiftSyntax.AttributeSyntax, syntax: String) -> String {
    switch node.arguments {
    case .argumentList(let exprs):
      let conds = exprs.compactMap {
          guard let platform = $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text else {
            return nil
          }
          return "os(\(platform))"
        }.joined(separator: " || ")
      
      if conds != "" {
        return
"""
#if \(conds)
\(syntax)
#endif
"""
      }
      return syntax

    default:
      return syntax
    }
  }
}


// MARK: - + MemberMacro

extension JvmMacro: MemberMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingMembersOf declaration: some DeclGroupSyntax,
                               conformingTo protocols: [TypeSyntax],
                               in context: some MacroExpansionContext) throws -> [DeclSyntax] {

    try assert(context: context)
    try assertSerializedIsApplicable(declaration)
    try assertDeclaredMarshallingIsUsable(declaration)
    try assertSerializedStoredPropertiesAreVisible(declaration)

    return try typeDecl(from: declaration).expandMembers(in: context)
  }
}


// MARK: - + MemberAttributeMacro

extension JvmMacro: MemberAttributeMacro {
  public static func expansion(of node: SwiftSyntax.AttributeSyntax,
                               attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
                               providingAttributesFor member: some SwiftSyntax.DeclSyntaxProtocol,
                               in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.AttributeSyntax] {

    if let decl = member.as(VariableDeclSyntax.self), decl.isExported {
      // On a serialized type a *stored* instance property is a Java field, so
      // the accessor thunks `@jvm_exported` generates would be registered
      // against methods the peer does not declare. A computed one is a
      // function, keeps being a method on the peer, and needs its thunks.
      // Statics keep theirs either way.
      // A stored property that crosses as some other type keeps its thunks:
      // its setter validates through Swift rather than writing the field.
      if isSerialized(declaration) && !decl.isStatic && decl.hasStoredBinding
          && !decl.hasDeclaredMarshalling {
        return []
      }
      return [AttributeSyntax(stringLiteral: "@jvm_exported")]
    }

    return []
  }
}


// MARK: - + PeerMacro

extension JvmMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax,
                               providingPeersOf declaration: some DeclSyntaxProtocol,
                               in context: some MacroExpansionContext) throws -> [DeclSyntax] {

    // Skip peer emission only when nested inside a real outer type (which
    // handles JNI registration itself). Types nested via extension namespace
    // (e.g. `extension Server { @jvm struct Subject }`) still need their own
    // register-natives peer so the JNI symbol matches the Java subpackage
    // (`Java_CaptureAPI_Server_Subject_Subject_1class_1init`). `expandPeer`
    // adapts the emission for ext-nested via `@_silgen_name` + `static`.
    guard context.enclosingDeclType == nil else {
      return []
    }

    return try typeDecl(from: declaration).expandPeer(in: context)
  }
}


// MARK: - + ExtensionMacro

extension JvmMacro: ExtensionMacro {
  public static func expansion(of node: SwiftSyntax.AttributeSyntax,
                               attachedTo declaration: some SwiftSyntax.DeclGroupSyntax,
                               providingExtensionsOf type: some SwiftSyntax.TypeSyntaxProtocol,
                               conformingTo protocols: [SwiftSyntax.TypeSyntax],
                               in context: some SwiftSyntaxMacros.MacroExpansionContext) throws -> [SwiftSyntax.ExtensionDeclSyntax] {

    try assert(context: context)

    // Value types additionally carry JvmPointerBoxed, which is what lets a
    // scoped borrow hand Java a peer around an address it does not own. A
    // class's peer already refers to the object itself, and taking the address
    // of a class-typed property would yield the address of the reference.
    // A serialized peer has no address to lend, so it cannot satisfy
    // JvmPointerBoxed's `fromUnownedPointer` and must not claim to.
    // JObjectUpdatable is what lets a nested member be written in place rather
    // than replaced, so a reference already held on the Java side does not
    // detach. A pointer-backed value type writes through its address; a
    // serialized one assigns field by field, but only where it can be mutated
    // at all. A class is excluded: its peer refers to the object, and a
    // property holding a different instance cannot be updated into the old one.
    let isValueType = declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self)
    var conformances = (isValueType && !isSerialized(declaration))
      ? "JObjectConvertible, JvmPointerBoxed"
      : "JObjectConvertible"

    // Structs only. An enum's peer is a sealed hierarchy or an ordinal, with no
    // address to write through and no field list to assign, so it has nothing
    // to update in place.
    let isStruct = declaration.is(StructDeclSyntax.self)
    if isStruct && (!isSerialized(declaration) || supportsMutation(declaration)) {
      conformances += ", JObjectUpdatable"
    }

    let extSyntax =
"""
extension \(type.trimmed): \(conformances) { }
"""
    return [try ExtensionDeclSyntax(SyntaxNodeString(stringLiteral: extSyntax))]
  }

}
