import SwiftSyntax
import SwiftParser

import SwiftSyntaxExtensions


class ClassGenerator<T: TypeDeclSyntax>: TypeGenerator<T> {
  private var varGens: [VarGenerator] = []
  private var methodGens: [MethodGenerator] = []

  private var ctorGens: [CtorGenerator] {
    typeDecl.exportedInitializers.map { CtorGenerator($0, className: name) }
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && node.parentDecl?.isExported ?? true {
      varGens.append(VarGenerator(node, className: name, observationTracking: typeDecl.isObservable))
    }
    return .skipChildren
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.isExported && node.parentDecl?.isExported ?? true {
      methodGens.append(MethodGenerator(node, className: name))
    }
    return .skipChildren
  }
}


extension ClassGenerator: TypeGeneratorProtocol {
  func generate(with ctx: inout Context) -> TypeProxy {
    let ctors = ctorGens.enumerated().map{$1.generate(with: &ctx, index: $0)}.joined(separator: "\n\n")

    var class_init =
"""
  static {
    \((registryParents.first ?? typeDecl).typeName).class_init();
  }
"""

    if !nested {
      class_init +=
"""

  private static void class_init() {
    if(!class_initialized) {
      \(name)_class_init();
      class_initialized = true;
    }
  }
  private static boolean class_initialized = false;
  private static native void \(name)_class_init();
"""
    }

    let source =
"""
public \(nested ? "static" : "") class \(name) {

\(class_init)

  private final SwiftPtr _ptr;
    
  private long _ptr() {
    return _ptr.get();
  }
  
  private static \(name) fromPtr(long ptr) {
    return new \(name)(new SwiftPtr(ptr, \(name)::deinit));
  }
  
  private static native void deinit(long ptr);
  
  private \(name)(SwiftPtr ptr) {
    _ptr = ptr;
  }

\(ctors)

\(varGens.map{$0.generate(with: &ctx)}.joined(separator: "\n\n"))

\(methodGens.map{$0.generate(with: &ctx)}.joined(separator: "\n\n"))

\(nestedTypeGens.compactMap {
    let proxy = $0.generate(with: &ctx)
    guard proxy is JavaTypeProxy else { return nil }
    return $0.generate(with: &ctx).source
  }
  .joined(separator: "\n\n")
)
}
"""
    return JavaTypeProxy(name: name, source: source)
  }
}
