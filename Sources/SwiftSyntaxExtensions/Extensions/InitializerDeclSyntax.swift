import SwiftSyntax


extension InitializerDeclSyntax: MemberDeclSyntax {
  public var name: TokenSyntax { .identifier("init") }

  public var isAsync: Bool {
    signature.effectSpecifiers?.asyncSpecifier != nil
  }

  public var isThrowing: Bool {
    signature.effectSpecifiers?.throwsClause != nil
  }

  /// True for a failable initializer (`init?` / `init!`). The peer returns a
  /// null (0) pointer on failure; the JVM side surfaces it as a nullable factory.
  public var isFailable: Bool {
    optionalMark != nil
  }
}
