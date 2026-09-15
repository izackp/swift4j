import SwiftSyntax


public protocol TypeDeclSyntax: ExportableDeclSyntax, DeclGroupSyntax, SyntaxHashable {
  var name: TokenSyntax { get }

  var exportedInitializers: [InitializerDeclSyntax] { get }
}


public extension TypeDeclSyntax {
  var exportedInitializers: [InitializerDeclSyntax] { [] }
}


public extension TypeDeclSyntax {
  typealias ExportedDecls = (initDecls: [InitializerDeclSyntax],
                             varDecls: [VariableDeclSyntax],
                             funcDecls: [FunctionDeclSyntax],
                             typeDecls: [any TypeDeclSyntax])

  var typeName: String { name.text }

  var isExported: Bool { !exportAttributes.isEmpty }

  var isMainActorIsolated: Bool? { hasAttribute("MainActor") }

  var exportAttributes: AttributeListSyntax {
    let attrs = attributes.findAttributes("jvm")
    return AttributeListSyntax(attrs)
  }

  /// Whether this type was declared `@jvm(serialized: true)`: its Java peer
  /// carries copied fields instead of a `SwiftPtr`, so it holds no native
  /// memory and is reclaimed by ordinary Java GC.
  ///
  /// Read from the attribute rather than inferred, because the choice is a
  /// lifetime contract ("valid until the next snapshot") that only the author
  /// can make. Defaults to false, so every existing `@jvm` type is unaffected.
  var isSerialized: Bool {
    for element in exportAttributes {
      guard case .attribute(let attr) = element,
            case .argumentList(let args)? = attr.arguments else { continue }

      for arg in args where arg.label?.text == "serialized" {
        guard let literal = arg.expression.as(BooleanLiteralExprSyntax.self) else { continue }
        return literal.literal.tokenKind == .keyword(.true)
      }
    }
    return false
  }

  /// Whether a Java value of this type carries enough to rebuild the Swift one.
  ///
  /// False when the type has a stored property that is neither marshalled nor
  /// recoverable without one — a `@nonjvm` one, typically. `LcUUID` is the case
  /// that matters: its only storage is `@nonjvm uuid: uuid_t`, so a generated
  /// reconstruction would quietly produce a zero UUID, which is a
  /// *valid-looking identifier for the wrong row*. Better to emit nothing and
  /// let the conformance fail to compile, which tells the author exactly where
  /// to write it by hand.
  ///
  /// An unmarshalled property is recoverable only when it is `Optional`, which
  /// rebuilds as `nil`. A default value is explicitly *not* enough: a default
  /// is precisely how a zero UUID would be forged.
  ///
  /// Lives here rather than in the macro because the CLI needs the same answer:
  /// it decides whether a serialized peer declares instance methods, and the
  /// macro decides whether to register their natives. A disagreement fails the
  /// whole `RegisterNatives` batch at class-init.
  var isSerializedReconstructible: Bool {
    for member in memberBlock.members {
      guard let decl = member.decl.as(VariableDeclSyntax.self),
            !decl.isStatic else { continue }
      // A declaration with no type annotation is invisible to `decls`, so it
      // could not be assigned even if it were exported.
      let storedBindings = decl.bindings.filter { $0.accessorBlock == nil }
      guard !storedBindings.isEmpty else { continue }
      if !decl.isExported {
        let recoverable = storedBindings.allSatisfy {
          $0.typeAnnotation?.type.is(OptionalTypeSyntax.self) == true
            && $0.initializer == nil
        }
        if !recoverable { return false }
        continue
      }
      if decl.decls.count != storedBindings.count { return false }
    }
    return true
  }

  /// A serialized peer can carry instance methods only when it can be rebuilt:
  /// the thunk reconstructs the receiver from the peer's fields before
  /// dispatching. Non-reconstructible types keep dropping them.
  var serializedDispatchesInstanceMethods: Bool {
    isSerialized && isSerializedReconstructible
  }

  var parents: [any TypeDeclSyntax] {
    var parents: [any TypeDeclSyntax] = []
    var cur: any TypeDeclSyntax = self

    while let parent = cur.parentDecl {
      parents.append(parent)
      cur = parent
    }

    return parents.reversed()
  }

  var initializers: [InitializerDeclSyntax] {
    memberBlock.members.compactMap {
      guard let initDecl = $0.decl.as(InitializerDeclSyntax.self) else { return nil }
      return initDecl
    }
  }

  var exportedDecls: ExportedDecls {
    var decls: ExportedDecls = (exportedInitializers, [], [], [])

    guard isExported else { return decls }

    for m in memberBlock.members {
      if let decl = m.decl.as(VariableDeclSyntax.self), decl.isExported {
        decls.varDecls.append(decl)

      } else if let decl = m.decl.as(FunctionDeclSyntax.self), decl.isExported {
        decls.funcDecls.append(decl)

      } else if let decl = m.decl.as(ClassDeclSyntax.self), decl.isExported {
        decls.typeDecls.append(decl)

      } else if let decl = m.decl.as(StructDeclSyntax.self), decl.isExported {
        decls.typeDecls.append(decl)

      } else if let decl = m.decl.as(EnumDeclSyntax.self), decl.isExported {
        decls.typeDecls.append(decl)
      }
    }

    return decls
  }

  func createInitializer(parameters: [FunctionParameterSyntax]) -> InitializerDeclSyntax {
    let paramsClause = FunctionParameterClauseSyntax(parameters: FunctionParameterListSyntax(parameters))
    return InitializerDeclSyntax(signature: FunctionSignatureSyntax(parameterClause: paramsClause))
  }

  /// True when the type's inheritance clause syntactically names `Error`,
  /// `LocalizedError`, or `CustomNSError`. Doesn't follow protocol chains
  /// (cross-file/cross-module conformance is invisible to syntax inspection)
  /// — covers the common direct-conformance case used by `@jvm` error types.
  var conformsToError: Bool {
    return inheritedTypeNames.contains { ["Error", "LocalizedError", "CustomNSError"].contains($0) }
  }

  /// True when the type's own inheritance clause syntactically names
  /// `Hashable`. Like `conformsToError`, this only inspects the primary
  /// declaration — a conformance added in a sibling `extension Foo: Hashable`
  /// is invisible here. The macro (Swift JNI thunks) and the CLI (Java
  /// proxy) both rely on this same check, so they must agree; that's only
  /// possible when the conformance lives on the main decl. Declare
  /// `: Hashable` on the type itself (the `==`/`hash(into:)` implementations
  /// may still live in an extension).
  ///
  /// Enums are excluded: their Java proxy comes from `EnumGenerator`, not
  /// `ClassGenerator`, so it wouldn't declare the `equals`/`hashCode` natives
  /// the macro would register — `RegisterNatives` would then fail to bind.
  /// Only `class`/`struct` (both → `ClassGenerator`) get the Hashable bridge.
  var conformsToHashable: Bool {
    return inheritedTypeNames.contains("Hashable") && !Syntax(self).is(EnumDeclSyntax.self)
  }

  /// Trimmed names from the type's own inheritance clause (empty for
  /// extensions / unsupported decls).
  private var inheritedTypeNames: [String] {
    let syntax = Syntax(self)
    let inheritanceClause: InheritanceClauseSyntax?
    if let cls = syntax.as(ClassDeclSyntax.self) {
      inheritanceClause = cls.inheritanceClause
    } else if let str = syntax.as(StructDeclSyntax.self) {
      inheritanceClause = str.inheritanceClause
    } else if let enm = syntax.as(EnumDeclSyntax.self) {
      inheritanceClause = enm.inheritanceClause
    } else {
      inheritanceClause = nil
    }
    guard let clause = inheritanceClause else { return [] }
    return clause.inheritedTypes.map { $0.type.trimmedDescription }
  }
}



extension ClassDeclSyntax: TypeDeclSyntax {
  public var exportedInitializers: [InitializerDeclSyntax] {
    let initializers = initializers

    if initializers.isEmpty {
      return [createInitializer(parameters: [])]

    } else {
      return initializers.filter { $0.isExported }
    }
  }
}

extension StructDeclSyntax: TypeDeclSyntax {
  public var exportedInitializers: [InitializerDeclSyntax] {
    let initializers = initializers

    if initializers.isEmpty {
      var varDecls: [VariableDeclSyntax] = []

      for member in memberBlock.members {
        if let varDecl = member.decl.as(VariableDeclSyntax.self) {
          if varDecl.isExported {
            varDecls.append(varDecl)
          } else if (varDecl.bindings.contains {$0.initializer == nil}) {
            // If there is a non-exported and non-initialized var in the struct,
            // do not generate any default init as it would need to expose such var
            return []
          }
        }
      }

      let params = varDecls.flatMap {
        $0.decls
      }.filter {
        !$0.initialized
      }.map {
        let name = TokenSyntax(.identifier($0.name), presence: .present)
        return FunctionParameterSyntax(firstName: name, type: $0.type)
      }

      return [createInitializer(parameters: params)]

    } else {
      return initializers.filter { $0.isExported }
    }
  }
}

extension EnumDeclSyntax: TypeDeclSyntax { }

