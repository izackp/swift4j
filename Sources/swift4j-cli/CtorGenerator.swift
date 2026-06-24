import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class CtorGenerator {
  private let initDecl: InitializerDeclSyntax
  private let className: String

  init(_ initDecl: InitializerDeclSyntax, className: String) {
    self.initDecl = initDecl
    self.className = className
  }

  var isFailable: Bool { initDecl.isFailable }

  /// `index` is the position among all initializers — it names the native peer
  /// (`init<index>`), which must match the JNI registration. `failableOrdinal` is
  /// the position among *failable* initializers only, used to name the public
  /// factory (`build`, `build1`, `build2`, …); nil for non-failable inits.
  func generate(with ctx: inout MethodGenerator.Context, index: Int, failableOrdinal: Int? = nil) -> String {
    let params = initDecl.signature.paramsMapping(with: &ctx)

    let callParams = params.map { $0.name }.joined(separator: ", ")
    let paramDecls = params.map { "\($0.type) \($0.name)" }.joined(separator: ", ")

    let throwsClause = initDecl.isThrowing ? " throws Exception" : ""

    // A failable Swift initializer (`init?`) can return nil, but a Java/Kotlin
    // constructor cannot return null. Emit a static factory returning the type
    // (nullable) instead — the native peer returns a 0 pointer on failure. The
    // first failable init is `build`; further ones get a numeric suffix to avoid
    // clashes when their parameter lists erase to the same Java signature.
    if initDecl.isFailable {
      let ordinal = failableOrdinal ?? 0
      let factory = ordinal == 0 ? "build" : "build\(ordinal)"
      return
"""
  public static \(className) \(factory)(\(paramDecls))\(throwsClause) {
    long ptr = init\(index)(\(callParams));
    if (ptr == 0) return null;
    return fromPtr(ptr);
  }
  private static native long init\(index)(\(paramDecls));
"""
    }

    return
"""
  public \(className)(\(paramDecls)) \(throwsClause) {
    this(new SwiftPtr(\(className).init\(index)(\(callParams)), \(className)::deinit));
  }
  private static native long init\(index)(\(paramDecls));
"""
  }
}
