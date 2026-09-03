import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

import SwiftSyntaxExtensions


extension StructDeclSyntax: JvmValueTypeDeclSyntax {
  func expandToJavaObject(in context: some MacroExpansionContext) -> String {
    return
"""
  let ptr = UnsafeMutablePointer<\(name.text)>.allocate(capacity: 1)
  ptr.initialize(to: self)
  return \(typeName).javaClass.callStaticObjectMethod(method: __JClass__.fromPtr, [Int(bitPattern: ptr).toJavaParameter()])
"""
  }
  

}


