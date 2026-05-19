

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
  let source: String

  func generate(in package: String, with imports: any Collection<String>) -> (filename: String, source: String) {
    let fullPackage: String
    let subdir: String
    if namespacePath.isEmpty {
      fullPackage = package
      subdir = ""
    } else {
      fullPackage = ([package] + namespacePath).joined(separator: ".")
      subdir = namespacePath.joined(separator: "/") + "/"
    }
    let content =
"""
package \(fullPackage);

import io.scade.swift4j.SwiftPtr;

\(imports.map{"import \($0);"}.joined(separator: "\n"))

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
