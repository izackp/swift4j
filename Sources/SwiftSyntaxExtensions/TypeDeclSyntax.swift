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
  /// There is no partial credit. An unmarshalled property used to count as
  /// recoverable when it was `Optional`, on the reasoning that rebuilding it as
  /// `nil` costs a reader nothing — but that is a claim about every downstream
  /// reader, which is not knowable from here. It made `Swift -> JVM -> Swift`
  /// return a value that differed from the one that went in, silently, in the
  /// one place nobody would look.
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
      guard decl.isExported || decl.hasDeclaredMarshalling else { return false }
      if decl.decls.count != storedBindings.count { return false }
    }
    return true
  }

  /// A serialized peer dispatches every instance member — methods and computed
  /// properties alike — on a receiver rebuilt from the peer.
  ///
  /// Deliberately *not* gated on `isSerializedReconstructible`. That gate was a
  /// second copy of the bug this file is built around: a type whose
  /// reconstruction the macro cannot synthesize had its instance members
  /// silently deleted from the Java surface, which is how an API loses methods
  /// without anyone being told.
  ///
  /// The thunk emits `Type.fromJavaObject(recv)`, and `fromJavaObject` is a
  /// `JObjectConvertible` requirement every `@jvm` type has to satisfy anyway.
  /// So a synthesized reconstruction works, a hand-written one works — that is
  /// the documented escape for storage the generator cannot marshal, such as
  /// `LcUUID`'s `uuid_t`, which being a tuple can carry no conformance at all —
  /// and a type with neither fails to compile, naming itself.
  var serializedDispatchesInstanceMethods: Bool {
    isSerialized
  }

  /// Whether a `mutating` method can be bridged: the thunk rebuilds the
  /// receiver, runs the mutation on that temporary, then copies every stored
  /// property back through the peer's setter, which is what makes the write
  /// visible to Java.
  ///
  /// Stricter than dispatch on purpose. A read only has to reach a receiver,
  /// however that receiver is built. A write has to land somewhere: an
  /// unmarshalled stored property has no field to copy back to, and a `let` has
  /// no setter to write through, so the mutation would vanish silently — worse
  /// than refusing the method.
  var serializedSupportsMutation: Bool {
    guard isSerialized else { return false }
    for member in memberBlock.members {
      guard let decl = member.decl.as(VariableDeclSyntax.self),
            !decl.isStatic else { continue }
      guard decl.bindings.contains(where: { $0.accessorBlock == nil }) else { continue }
      if !decl.isExported && !decl.hasDeclaredMarshalling { return false }
      if decl.bindingSpecifier.tokenKind == .keyword(.let) { return false }
    }
    return true
  }

  /// Whether the serialized peer needs the checked/unchecked constructor pair.
  ///
  /// A property carrying `@jvm(as:toJava:toSwift:)` can be handed a Java value
  /// that `toSwift` refuses, and the all-fields constructor stores it raw — so
  /// the reconstruction's `try!` traps on the next read, in Swift, with no
  /// catchable Java frame. The checked constructor writes such a property
  /// through its own checked setter, which converts in Swift and reports a
  /// failure as a Java exception at the `new` that caused it.
  ///
  /// Both generators read this: the CLI declares the pair, the macro builds the
  /// descriptor it calls. A disagreement is a missing-constructor failure at
  /// class-init.
  var serializedHasCheckedCtor: Bool {
    guard isSerialized else { return false }
    return exportedDecls.varDecls
      .filter { !$0.isStatic }
      .flatMap { $0.decls }
      .contains { !$0.computed && $0.marshalling != nil && !$0.readonly }
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

