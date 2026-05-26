import SwiftSyntax
import SwiftSyntaxMacros
import SwiftCompilerPlugin

@main
struct Swift4jStubPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        NoOpPeerMacro.self
    ]
}

public struct NoOpPeerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}
