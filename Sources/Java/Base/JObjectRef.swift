//
//  JObjectRef.swift
//  Java
//
//  Created by Grigory Markin on 04.02.25.
//

#if os(Linux) || os(Android)
  import Glibc
#else
  import Darwin
#endif

public final class JObjectRef<T: JObjectConvertible & AnyObject>: @unchecked Sendable {
  private var jobj: JObject?

  private var mutex = pthread_mutex_t()

  public init(jobj: JObject? = nil) {
    self.jobj = jobj
    pthread_mutex_init(&self.mutex, nil)
  }

  deinit {
    pthread_mutex_destroy(&self.mutex)
  }

  public func from(_ obj: T) -> JavaObject {
    return withLock { jobj in
      // The cached peer is held weakly: it is the back-edge to the object that
      // owns this Swift instance, so pinning it would make a cross-runtime
      // cycle neither collector could break. That means two things here — the
      // reference must be promoted before it can be used, and a promotion that
      // fails means the peer was collected and a fresh one is needed.
      if let cached = jobj, let local = cached.localRef() {
        return local
      }

      let params = [JavaLong(Int(bitPattern: Unmanaged.passRetained(obj).toOpaque())).toJavaParameter()]
      let peer = JObject(T.javaClass.callStaticObjectMethod(method: "fromPtr", sig: "(J)\(T.javaSignature)", params)!, weak: true)
      jobj = peer

      guard let local = peer.localRef() else {
        fatalError("JObjectRef.from: NewLocalRef failed for a freshly created peer")
      }
      return local
    }
  }

  public func release() {
    withLock {
      $0 = nil
    }
  }

  private func withLock<R>(_ body: (inout JObject?) -> R) -> R {
    pthread_mutex_lock(&self.mutex); defer { pthread_mutex_unlock(&self.mutex) }
    return body(&jobj)
  }
}
