import SwiftSyntax


extension VariableDeclSyntax: MemberDeclSyntax {
  public struct VarDecl {
    public let name: String
    /// The type as it crosses. For a property carrying
    /// `@jvm(as:toJava:toSwift:)` this is the declared Java-side type, not the
    /// Swift one — every generator that sizes a field, builds a constructor
    /// parameter or writes a JNI descriptor wants the type that actually
    /// crosses, and only the thunk bodies care about the Swift type.
    public let type: TypeSyntax
    public let initialized: Bool
    public let readonly: Bool
    public let computed: Bool
    /// Non-nil when the two sides differ, carrying the conversions between them.
    public let marshalling: JvmMarshalling?

    public var capitalizedName: String {
      name.first!.uppercased() + name.dropFirst()
    }

    /// The property read, converted to its Java-side form where it needs to be.
    public func javaValue(of base: String) -> String {
      guard let marshalling else { return "\(base).\(name)" }
      return "(\(marshalling.toJava.trimmedDescription))(\(base).\(name))"
    }

    /// The Java-side value converted back to what the Swift property holds.
    public func swiftValue(from expr: String) -> String {
      guard let marshalling else { return expr }
      return "(\(marshalling.toSwift.trimmedDescription))(\(expr))"
    }
  }

  public var decls: [VarDecl] {
    let marshalling = jvmMarshalling
    return bindings.compactMap {
      guard let name = $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
        return nil
      }

      guard let type = $0.typeAnnotation?.type else {
        return nil
      }

      let hasComputedGet: Bool
      let hasComputedSet: Bool

      if let accessorBlock = $0.accessorBlock {
        hasComputedGet = accessorBlock.hasGetter
        hasComputedSet = accessorBlock.hasSetter && (accessorVisibility("set") != .private)
      } else {
        hasComputedGet = false
        hasComputedSet = false
      }

      return VarDecl(name: name,
                     type: marshalling?.javaType ?? type,
                     initialized: $0.initializer != nil || $0.accessorBlock != nil,
                     readonly: bindingSpecifier.tokenKind == .keyword(.let) || (hasComputedGet && !hasComputedSet),
                     computed: hasComputedGet,
                     marshalling: marshalling)
    }
  }

  /// Whether this declaration introduces storage. The distinction matters on a
  /// `@jvm(serialized:)` type, where storage becomes a Java field and a
  /// computed property stays a method.
  public var hasStoredBinding: Bool {
    bindings.contains { $0.accessorBlock == nil }
  }

  /// A property's declared marshalling, from `@jvm(as:toJava:toSwift:)`.
  ///
  /// Both generators read this off the declaration, which is the whole reason
  /// it is written there: the macro sees a single file, so it could never
  /// resolve a conformance to decide the same question, and the two sides
  /// disagreeing fails the entire `RegisterNatives` batch.
  public struct JvmMarshalling {
    public let javaType: TypeSyntax
    public let toJava: ExprSyntax
    public let toSwift: ExprSyntax
  }

  public var jvmMarshalling: JvmMarshalling? {
    for element in attributes.findAttributes("jvm") {
      guard case .attribute(let attr) = element,
            case .argumentList(let args)? = attr.arguments else { continue }

      var javaType: TypeSyntax?
      var toJava: ExprSyntax?
      var toSwift: ExprSyntax?

      for arg in args {
        switch arg.label?.text {
        case "as":
          // `String.self` — the metatype expression names the type.
          if let base = arg.expression.as(MemberAccessExprSyntax.self)?.base,
             let ref = base.as(DeclReferenceExprSyntax.self) {
            javaType = TypeSyntax(IdentifierTypeSyntax(name: ref.baseName))
          }
        case "toJava": toJava = arg.expression
        case "toSwift": toSwift = arg.expression
        default: break
        }
      }

      if let javaType, let toJava, let toSwift {
        return JvmMarshalling(javaType: javaType, toJava: toJava, toSwift: toSwift)
      }
    }
    return nil
  }

  public var isAsync: Bool {
    ///TODO: implement for computed properties
    return false
  }

  public var isThrowing: Bool {
    ///TODO: implement for computed properties
    return false
  }

  func accessorVisibility(_ acc: String) -> Visibility? {
    for mod in modifiers {
      if let modDetail = mod.detail?.detail.tokenKind, modDetail == .identifier(acc) {
        if let visibility = Visibility(rawValue: mod.name.text) {
          return visibility
        }
      }
    }
    return nil
  }
}


fileprivate extension AccessorBlockSyntax {
  var hasSetter: Bool {
    guard case .accessors(let accessorDecls) = self.accessors else {
      return false
    }

    return accessorDecls.contains{ $0.accessorSpecifier.tokenKind == .keyword(.set) }
  }

  var hasGetter: Bool {
    switch accessors {
      case .accessors(let accessorDecls):
        return accessorDecls.contains{ $0.accessorSpecifier.tokenKind == .keyword(.get) }
      case .getter:
        return true
    }
  }
}
