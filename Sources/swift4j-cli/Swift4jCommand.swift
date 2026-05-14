import Foundation
import ArgumentParser

@main
struct Swift4jCommand: ParsableCommand {
  @Option(name: .shortAndLong,
          help: "Output directory")
  var outdir: String?

  @Option(name: .long,
          help: "Java package name")
  var package: String
  
  @Option(name: .long,
          help: "Java version")
  var javaVersion: Int = 11

  @Flag(name: .long,
          help: "Generate Android ViewModels for Swift Observables",)
  var generateAndroidViewModels: Bool = false

  // Repeatable: `--external-type TypeName=java.package`. Lets the codegen
  // emit `import java.package.TypeName;` when it encounters `TypeName` in
  // a parameter/return position from a different Swift module. Without
  // this, cross-package references compile to an unqualified name that
  // resolves to the current package and fails to load.
  @Option(name: .long,
          parsing: .upToNextOption,
          help: "External type to package mapping (TypeName=java.package)")
  var externalType: [String] = []

  @Flag(name: .long,
        help: "Scan mode: print discovered @jvm top-level type names (one per line) to stdout and exit. Does not write any files.")
  var scanTypes: Bool = false

  @Argument(help: "Input filenames.")
  var paths: [String] = []
  

  mutating func validate() throws {
    if paths.isEmpty {
      throw ValidationError("Input is empty.")
    }

    var isDir: ObjCBool = false

    for p in paths {
      if !FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
        throw ValidationError("\(p) does not exist.")
      }

      if isDir.boolValue {
        throw ValidationError("\(p) is a path to a directory, not a Swift source file.")
      }
    }

    if let outdir = outdir {
      if !FileManager.default.fileExists(atPath: outdir, isDirectory: &isDir) {
        throw ValidationError("\(outdir) does not exist.")
      }

      if !isDir.boolValue {
        throw ValidationError("\(outdir) is a path to a file, not a directory.")
      }
    }
  }


  mutating func run() throws {
    if scanTypes {
      try runScan()
      return
    }

    let externalPackages = try parseExternalTypes()
    let proxyGenerator = ProxyGenerator(package: package, javaVersion: javaVersion, externalPackages: externalPackages)
    let viewModelGenerator = ViewModelsGenerator(package: package)

    for res in try proxyGenerator.run(paths: paths) {
      try write(res.source, to: res.filename)
    }

    if generateAndroidViewModels {
      for p in paths {
        for res in try viewModelGenerator.run(path: p) {
          try write(res.content, to: "viewmodel/\(res.classname).kt")
        }
      }
    }

    // let packageClass = generator.generatePackageClass()
    // try packageClass.write(to: filename(for: "\(package)_module"), atomically: true, encoding: .utf8)
  }

  private func parseExternalTypes() throws -> [String: String] {
    var map: [String: String] = [:]
    for entry in externalType {
      let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        throw ValidationError("--external-type expects 'TypeName=java.package', got '\(entry)'")
      }
      map[parts[0]] = parts[1]
    }
    return map
  }

  private func runScan() throws {
    let names = try ProxyGenerator.scanTopLevelJvmTypes(paths: paths).sorted()
    for n in names {
      print(n)
    }
  }

  

  private func write(_ content: String, to classpath: String) throws {
    if let outdir = outdir {
      var pkgDir: URL

      if #available(macOS 13.0, *) {
        pkgDir = URL(filePath: "\(outdir)/\(package)")
      } else {
        pkgDir = URL(fileURLWithPath: "\(outdir)/\(package)")
      }

      let pathComponents = classpath.split(separator: "/")
      guard let filename = pathComponents.last else {
        fatalError("Invalid path: \(classpath)")
      }
      let pkgSubdir = pathComponents.dropLast().joined(separator: "/")

      if #available(macOS 13.0, *) {
        pkgDir = pkgDir.appending(path: pkgSubdir)
      } else {
        pkgDir = pkgDir.appendingPathComponent(pkgSubdir)
      }

      let pkgDirPath: String
      if #available(macOS 13.0, *) {
        pkgDirPath = pkgDir.path()
      } else {
        pkgDirPath = pkgDir.path
      }

      var isDirectory: ObjCBool = false
      if !FileManager.default.fileExists(atPath: pkgDirPath, isDirectory: &isDirectory) {
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
      }

      let dest: URL
      if #available(macOS 13.0, *) {
        dest = pkgDir.appending(path: filename)
      } else {
        dest = pkgDir.appendingPathComponent(String(filename))
      }

      try content.write(to: dest, atomically: true, encoding: .utf8)

    } else {

      print(content, "\n")
    }

  }
}
