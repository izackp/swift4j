// Bridges Swift Dictionary<Key, Value> to java.util.HashMap.
//
// Both Key and Value must conform to JConvertible. Conversion is by
// copy: Swift dict -> new HashMap (put each entry), HashMap -> Swift
// dict (entrySet().iterator() loop). For large maps this is O(n)
// per direction.

import CJNI


fileprivate let _hashMapClass: JClass = {
  guard let cls = findJavaClass(fqn: "java/util/HashMap") else {
    fatalError("java.util.HashMap not found")
  }
  return cls
}()

fileprivate let _hashMapInit: JavaMethodID = {
  guard let mid = _hashMapClass.getMethodID(name: "<init>", sig: "(I)V") else {
    fatalError("HashMap.<init>(int) not found")
  }
  return mid
}()

fileprivate let _hashMapPut: JavaMethodID = {
  guard let mid = _hashMapClass.getMethodID(name: "put", sig: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") else {
    fatalError("HashMap.put not found")
  }
  return mid
}()

fileprivate let _mapClass: JClass = {
  guard let cls = findJavaClass(fqn: "java/util/Map") else {
    fatalError("java.util.Map not found")
  }
  return cls
}()

fileprivate let _mapEntrySet: JavaMethodID = {
  guard let mid = _mapClass.getMethodID(name: "entrySet", sig: "()Ljava/util/Set;") else {
    fatalError("Map.entrySet not found")
  }
  return mid
}()

fileprivate let _setClass: JClass = {
  guard let cls = findJavaClass(fqn: "java/util/Set") else {
    fatalError("java.util.Set not found")
  }
  return cls
}()

fileprivate let _setIterator: JavaMethodID = {
  guard let mid = _setClass.getMethodID(name: "iterator", sig: "()Ljava/util/Iterator;") else {
    fatalError("Set.iterator not found")
  }
  return mid
}()

fileprivate let _iteratorClass: JClass = {
  guard let cls = findJavaClass(fqn: "java/util/Iterator") else {
    fatalError("java.util.Iterator not found")
  }
  return cls
}()

fileprivate let _iteratorHasNext: JavaMethodID = {
  guard let mid = _iteratorClass.getMethodID(name: "hasNext", sig: "()Z") else {
    fatalError("Iterator.hasNext not found")
  }
  return mid
}()

fileprivate let _iteratorNext: JavaMethodID = {
  guard let mid = _iteratorClass.getMethodID(name: "next", sig: "()Ljava/lang/Object;") else {
    fatalError("Iterator.next not found")
  }
  return mid
}()

fileprivate let _entryClass: JClass = {
  guard let cls = findJavaClass(fqn: "java/util/Map$Entry") else {
    fatalError("java.util.Map$Entry not found")
  }
  return cls
}()

fileprivate let _entryGetKey: JavaMethodID = {
  guard let mid = _entryClass.getMethodID(name: "getKey", sig: "()Ljava/lang/Object;") else {
    fatalError("Map.Entry.getKey not found")
  }
  return mid
}()

fileprivate let _entryGetValue: JavaMethodID = {
  guard let mid = _entryClass.getMethodID(name: "getValue", sig: "()Ljava/lang/Object;") else {
    fatalError("Map.Entry.getValue not found")
  }
  return mid
}()


extension Dictionary: JParameterConvertible, JConvertible, JNullInitializable, JObjectConvertible
where Key: JObjectConvertible, Value: JObjectConvertible {

  public static var javaSignature: String { "Ljava/util/Map;" }

  public static var javaName: String { "java/util/Map" }

  public static var javaClass: JClass { _mapClass }

  public func toJavaObject() -> JavaObject? {
    let map = _hashMapClass.create(ctor: _hashMapInit, [JavaParameter(int: JavaInt(self.count))])
    let mapObj = JObject(map)
    for (k, v) in self {
      let kObj = k.toJavaObject()
      let vObj = v.toJavaObject()
      let _ = mapObj.callObjectMethod(method: _hashMapPut,
                                      [JavaParameter(object: kObj),
                                       JavaParameter(object: vObj)])
      if let kObj = kObj, jni.GetObjectRefType(kObj).rawValue == 1 {
        jni.DeleteLocalRef(kObj)
      }
      if let vObj = vObj, jni.GetObjectRefType(vObj).rawValue == 1 {
        jni.DeleteLocalRef(vObj)
      }
    }
    return map
  }

  public static func fromJavaObject(_ obj: JavaObject) -> Dictionary<Key, Value> {
    var result: [Key: Value] = [:]
    let mapObj = JObject(obj)
    guard let entrySet = mapObj.callObjectMethod(method: _mapEntrySet, []) else { return result }
    let setObj = JObject(entrySet)
    guard let iter = setObj.callObjectMethod(method: _setIterator, []) else {
      jni.DeleteLocalRef(entrySet)
      return result
    }
    let iterObj = JObject(iter)
    while true {
      let hasNext: Bool = iterObj.call(method: _iteratorHasNext, [])
      if !hasNext { break }
      guard let entry = iterObj.callObjectMethod(method: _iteratorNext, []) else { break }
      let entryObj = JObject(entry)
      let kPtr = entryObj.callObjectMethod(method: _entryGetKey, [])
      let vPtr = entryObj.callObjectMethod(method: _entryGetValue, [])
      if let kPtr = kPtr, let vPtr = vPtr {
        let key = Key.fromJavaObject(kPtr)
        let value = Value.fromJavaObject(vPtr)
        result[key] = value
      }
      if let kPtr = kPtr, jni.GetObjectRefType(kPtr).rawValue == 1 {
        jni.DeleteLocalRef(kPtr)
      }
      if let vPtr = vPtr, jni.GetObjectRefType(vPtr).rawValue == 1 {
        jni.DeleteLocalRef(vPtr)
      }
      if jni.GetObjectRefType(entry).rawValue == 1 {
        jni.DeleteLocalRef(entry)
      }
    }
    jni.DeleteLocalRef(iter)
    jni.DeleteLocalRef(entrySet)
    return result
  }
}
