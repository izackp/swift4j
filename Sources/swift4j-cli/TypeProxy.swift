

protocol TypeProxy {
  var name: String { get }
  var source: String { get }

  func generate(in package: String, with imports: any Collection<String>) -> (filename: String, source: String)
}


struct JavaTypeProxy : TypeProxy {
  let name: String
  /// Namespace extension path the type lives under (e.g. `["Server"]`).
  /// Drives Java subpackage emission so `extension Server { @jvm struct Subject }`
  /// becomes `<basePackage>/Server/Subject.java` with package
  /// `<basePackage>.Server`.
  var namespacePath: [String] = []
  /// A serialized peer holds no pointer, so importing `SwiftPtr` would be a
  /// visible lie about what the class is — and the only signal a reader has
  /// that it is not a handle.
  var needsSwiftPtr: Bool = true
  let source: String

  func generate(in package: String, with imports: any Collection<String>) -> (filename: String, source: String) {
    let fullPackage: String
    let subdir: String
    var importLines = imports.map { "import \($0);" }
    if namespacePath.isEmpty {
      fullPackage = package
      subdir = ""
    } else {
      fullPackage = ([package] + namespacePath).joined(separator: ".")
      subdir = namespacePath.joined(separator: "/") + "/"
      // Namespaced subpackages can't see sibling top-level @jvm types in the
      // base package without an explicit import. Pull all of them in.
      importLines.append("import \(package).*;")
    }
    let content =
"""
package \(fullPackage);
\(needsSwiftPtr ? "\nimport io.scade.swift4j.SwiftPtr;\n" : "")
\(importLines.joined(separator: "\n"))

\(source)
"""
    return (filename: "\(subdir)\(name).java", content)
  }
}


struct KotlinTypeProxy : TypeProxy {
  let name: String
  let source: String

  func generate(in package: String, with imports: any Collection<String>) -> (filename: String, source: String) {
    let content =
"""
package \(package)

import io.scade.swift4j.SwiftPtr 

\(imports.map{"import \($0)"}.joined(separator: "\n"))

\(source)
"""
    return (filename: "\(name).kt", content)
  }
}
