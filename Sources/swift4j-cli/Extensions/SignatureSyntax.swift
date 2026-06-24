import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


extension SignatureSyntax {
  func paramsMapping(with ctx: inout ProxyGenerator.Context) -> [(name: String, type: String)] {
    parameters.map { $0.map(with: &ctx) }
  }
}


extension ParameterSyntax {
  func map(with ctx: inout ProxyGenerator.Context) -> (name: String, type: String) {
    (name: (name ?? "").javaSafeParamName, type: type.map(with: &ctx))
  }
}

// Java reserved words can't be used as parameter identifiers in the generated
// Java. The name is cosmetic on the Java side (JNI binds by name + signature,
// not parameter names) and is used consistently for both the method decl and
// the forwarding call, so escaping it here is safe.
private let javaReservedWords: Set<String> = [
  "abstract","assert","boolean","break","byte","case","catch","char","class","const",
  "continue","default","do","double","else","enum","extends","final","finally","float",
  "for","goto","if","implements","import","instanceof","int","interface","long","native",
  "new","package","private","protected","public","return","short","static","strictfp",
  "super","switch","synchronized","this","throw","throws","transient","try","void",
  "volatile","while","true","false","null","var","record","yield",
]

private extension String {
  var javaSafeParamName: String { javaReservedWords.contains(self) ? self + "_" : self }
}
