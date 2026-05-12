import PackagePlugin
import Foundation



@main
struct GenerateJavaBridgingPlugin: CommandPlugin {

  func performCommand(context: PluginContext, arguments: [String]) throws {
    let overallStart = Date()
    let toolPath = try URL(filePath: context.tool(named: "swift4j-cli").path.string)
    let outputDir = context.pluginWorkDirectory

    var argExtractor = ArgumentExtractor(arguments)
    let prodNames = argExtractor.extractOption(named: "product")
    let copyJavaSources = argExtractor.extractFlag(named: "copy-java-sources") > 0

    let products = prodNames.isEmpty
      ? context.package.products
      : try context.package.products(named: prodNames)

    print("[swift4j] generate-java-bridging start: \(products.count) product(s) [\(products.map{$0.name}.joined(separator: ", "))], outputDir=\(outputDir.string)")

    for prod in products  {
      let prodOutputDir = outputDir.appending(prod.name)
      let pkgsOutDir = prodOutputDir.appending(["main", "java"])
      // Wipe once per product so a stale package from a previous run can't
      // linger; per-module iterations below append to this directory.
      if FileManager.default.fileExists(atPath: pkgsOutDir.string) {
        try FileManager.default.removeItem(atPath: pkgsOutDir.string)
      }
      try FileManager.default.createDirectory(at: URL(filePath: pkgsOutDir.string), withIntermediateDirectories: true)

      let modules = prod.targets.flatMap{$0.recursiveTargetSourceModules(followProducts: true)}
      print("[swift4j] product '\(prod.name)': \(modules.count) reachable source module(s)")
      // Only run swift4j-cli on modules that actually depend on Swift4j.
      // Everything else (swift-syntax, GRDB, swift-crypto, the Swift4j runtime
      // target itself, etc.) has no @jvm types and would just emit noise — or,
      // worse, slow the plugin to a crawl when source files number in the
      // hundreds.
      let bridgeable = modules.filter { $0.name != "Swift4j" && dependsOnSwift4j($0) }
      print("[swift4j] product '\(prod.name)': bridging \(bridgeable.count) module(s) [\(bridgeable.map{$0.name}.joined(separator: ", "))], skipping \(modules.count - bridgeable.count)")
      try bridgeable.forEach {
        let moduleStart = Date()
        let pkgName = $0.name.replacingOccurrences(of: "-", with: "_")
        let sourceCount = $0.sourceFiles.filter{ $0.path.string.hasSuffix(".swift") }.underestimatedCount
        print("[swift4j]   '\($0.moduleName)' -> '\(pkgName)' (\(sourceCount) swift sources)")
        try generate(for: $0,
                     pkgName: pkgName,
                     pkgsOutDir: pkgsOutDir,
                     with: toolPath,
                     forwardArgs: argExtractor.remainingArguments,
                     copyJavaSources: copyJavaSources)
        print("[swift4j]   '\($0.moduleName)' done in \(String(format: "%.2f", Date().timeIntervalSince(moduleStart)))s")
      }
    }
    print("[swift4j] generate-java-bridging complete in \(String(format: "%.2f", Date().timeIntervalSince(overallStart)))s")
  }

  private func generate(for sourceModule: any SourceModuleTarget,
                        pkgName: String,
                        pkgsOutDir: PackagePlugin.Path,
                        with toolPath: URL,
                        forwardArgs args: [String],
                        copyJavaSources: Bool = false) throws {

    let arguments = args
      + ["-o", pkgsOutDir.string, "--package", pkgName]
      + sourceModule.sourceFiles.map{ $0.path.string }.filter{$0.hasSuffix(".swift")}

    try Process.run(toolPath, arguments: arguments)

    if copyJavaSources {
      try self.copyJavaSources(from: sourceModule, to: pkgsOutDir)
    }
  }

  private func copyJavaSources(from sourceModule: any SourceModuleTarget,
                               to outputDir: PackagePlugin.Path) throws {

    let javaSources = sourceModule.recursiveTargetSourceModules(followProducts: true).flatMap {
      $0.sourceFiles.filter { srcFile in
        srcFile.type == .resource && srcFile.path.string.hasSuffix(".java")
      }
    }
    
    try javaSources.forEach {
      if let pkgName = try? javaPackageName(from: $0.path) {
        let outPath = outputDir.appending(pkgName.split(separator: ".").map(String.init))

        try FileManager.default.createDirectory(at: URL(filePath: outPath.string), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: $0.path.string, toPath: outPath.appending($0.path.lastComponent).string)
      }
    }

  }

  private func javaPackageName(from path: Path) throws -> String? {
    let fileURL = URL(fileURLWithPath: path.string)
    let fileContents = try String(contentsOf: fileURL, encoding: .utf8)

    let pattern = #"package\s+([a-zA-Z_][\w]*(?:\.[a-zA-Z_][\w]*)*);"#

    guard let regex = try? Regex(pattern),
          let match = fileContents.firstMatch(of: regex),
          let packageName = match.output[1].substring else { return nil }

    return String(packageName)
  }

}


/// True if the given source module pulls in the Swift4j target either directly
/// or transitively via any product dependency.
func dependsOnSwift4j(_ module: any SourceModuleTarget) -> Bool {
  var seen = Set<String>()

  func walk(_ deps: [TargetDependency]) -> Bool {
    for dep in deps {
      switch dep {
      case .target(let t):
        if t.name == "Swift4j" { return true }
        if seen.insert(t.id).inserted, let sm = t.sourceModule, walk(sm.dependencies) {
          return true
        }
      case .product(let p):
        if p.name == "Swift4j" { return true }
        for t in p.targets {
          if t.name == "Swift4j" { return true }
          if seen.insert(t.id).inserted, let sm = t.sourceModule, walk(sm.dependencies) {
            return true
          }
        }
      default:
        continue
      }
    }
    return false
  }

  return walk(module.dependencies)
}


extension Target {
  func recursiveTargetSourceModules(followProducts: Bool = false) -> [any SourceModuleTarget] {
    var modules = [any SourceModuleTarget]()
    var processed = Set<String>()

    func process(_ target: any Target) {
      guard !processed.contains(target.id) else { return }

      if let sm = target.sourceModule {
        modules.append(sm)
        processed.insert(target.id)

        sm.dependencies.forEach(traverse)
      }
    }

    func traverse(_ dep: TargetDependency) {
      switch dep {
      case .target(let target):
        // print("Target: \(target.name)")
        process(target)

      case .product(let prod):
        guard followProducts else { return }
        // print("Product: \(prod.name)")
        prod.targets.forEach(process)
        
      default:
        return
      }
    }
    
    process(self)

    return modules
  }
}
