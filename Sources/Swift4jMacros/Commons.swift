import Foundation
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions

public enum JvmMacrosError: Swift.Error, CustomStringConvertible {
  case message(String, Optional<SyntaxProtocol> = nil)

  public var description: String {
    switch self {
    case .message(let msg, _): return msg
    }
  }
}

struct JvmMacrosWarnDiagnostic: DiagnosticMessage {
  let message: String

  var severity: DiagnosticSeverity = .warning

  var diagnosticID: MessageID {
    .init(domain: "SwiftJavaMacros", id: "JavaMacrosErrorDiagnostic")
  }
}

extension MacroExpansionContext {

  var enclosingDeclType: (any JvmTypeDeclSyntax)? {
    lexicalContext.first?.asProtocol(DeclSyntaxProtocol.self) as? (any JvmTypeDeclSyntax)
  }

  /// Names of `extension Foo { ... }` blocks enclosing the declaration being
  /// expanded, ordered outermost-first. Used to namespace `@jvm` types so
  /// e.g. `extension Server { @jvm struct Subject }` emits Java class
  /// `Server.Subject` (inner class `Server$Subject` at JNI level) instead of
  /// colliding with a top-level `Subject` declared elsewhere.
  ///
  /// Walks stop at the first real `TypeDeclSyntax` — past that point the
  /// declaration is genuinely nested inside another type, and the existing
  /// `parents` chain machinery already handles it.
  ///
  /// Only simple-identifier extended types are captured; member-typed
  /// extensions (`extension Foo.Bar { … }`) are skipped to avoid
  /// double-prefixing.
  var namespaceParentNames: [String] {
    var names: [String] = []
    for node in lexicalContext {
      if (node.asProtocol(DeclSyntaxProtocol.self) as? (any TypeDeclSyntax)) != nil {
        break
      }
      if let ext = node.as(ExtensionDeclSyntax.self),
         let id = ext.extendedType.as(IdentifierTypeSyntax.self) {
        names.append(id.name.text)
      }
    }
    return names.reversed()
  }

  func executeAndWarnIfFails<T>(at node: some SyntaxProtocol, _ f: () throws -> T) -> T? {
    do {
      return try f()

    } catch {
      if let err = error as? JvmMacrosError {
        switch err {
        case .message(let msg, .some(let errNode)):

          self.diagnose(Diagnostic(node: Syntax(errNode),
                                   message: JvmMacrosWarnDiagnostic(message: msg),
                                   fixIts: disableJvmMappingFixIt(at: node)))
          return nil
        default:
          break
        }
      }
      self.addDiagnostics(from: error, node: node)
      return nil
    }
  }

  func disableJvmMappingFixIt(at node: some SyntaxProtocol) -> [FixIt] {
    var newNode: Syntax? = nil
    
    var nonjvmAttr: AttributeListSyntax.Element = .attribute("@nonjvm")
    nonjvmAttr.trailingTrivia = .newline

    if let funcDecl = node.as(FunctionDeclSyntax.self) {
      var newFuncDecl = funcDecl.trimmed
      newFuncDecl.attributes.append(nonjvmAttr)
      newNode = Syntax(newFuncDecl)

    } else if let initDecl = node.as(InitializerDeclSyntax.self) {
      var newInitDecl = initDecl.trimmed
      newInitDecl.attributes.append(nonjvmAttr)
      newNode = Syntax(newInitDecl)
    }

    guard let newNode = newNode else {
      return []
    }
    
    return [FixIt(message: DisableJvmMappingFixItMessage(),
                  changes: [
                    FixIt.Change.replace(oldNode: Syntax(node),
                                         newNode: Syntax(newNode))
                 ])]
  }
}

struct DisableJvmMappingFixItMessage: FixItMessage {
  var message = "Add @nonjvm attribute to disable mapping for the given class member"

  var fixItID: MessageID {
    .init(domain: "SwiftJavaMacros", id: "DisableJavaMappingFixIt")
  }


}
