
final class JCompletableFuture: @unchecked Sendable {
  private var jobj: JObject?

  init(_ ptr: JavaObject) {
    jobj = JObject(ptr)
  }

  func release() {
    jobj = nil
  }

  func complete<T: JConvertible>(_ value: T) -> Bool {
    return complete(value.toJavaObject())
  }

  func complete<T: Error>(_ error: T) -> Bool {
    return jobj!.call(method: "completeExceptionally",
                      sig: "(Ljava/lang/Throwable;)Z",
                      [JavaParameter(object: error.toJavaObject())])
  }

  func complete(_ value: JavaObject?) -> Bool {
    return jobj!.call(method: "complete", sig: "(Ljava/lang/Object;)Z",
                      [JavaParameter(object: value)])
  }

  func complete() -> Bool {
    return jobj!.call(method: "complete", sig: "(Ljava/lang/Object;)Z",
                      [JavaParameter(object: nil)])
  }
}

public func execWithFuture<T: JConvertible & Sendable>(
  _ cl: @Sendable @escaping () async throws -> T
) -> JavaObject {
  guard let javaObject = JCompletableFuture__class?.create() else {
    fatalError("CompletableFuture class is not available")
  }

  let future = JCompletableFuture(javaObject)

  Task.detached {
    // Two JNI-lifecycle invariants must hold together:
    //
    // 1. JNI local refs are thread-local AND scoped to the frame that
    //    created them. Using one on a different thread (or after the
    //    creating frame returns) is undefined → CheckJNI aborts with
    //    "invalid JNI transition frame reference".
    //
    // 2. We need to hand the Java value off to `future.complete(...)` on
    //    Main (`await MainActor.run` below). That hop is a guaranteed
    //    suspension + thread change.
    //
    // Therefore: `toJavaObject()` and `NewGlobalRef` MUST run in the same
    // synchronous frame here, with no `await` in between. The global ref
    // is safe to carry across the MainActor hop; the local is not.
    let res: Result<JavaObject?, Error>
    do {
      let value = try await cl()
      res = .success(withLocalFrame {
        value.toJavaObject().flatMap { jni.NewGlobalRef($0) }
      })
    } catch {
      res = .failure(error)
    }

    await MainActor.run {
      switch res {
        case .success(let val):
          _ = future.complete(val)
          if let val { jni.DeleteGlobalRef(val) }
        case .failure(let err):
          withLocalFrame { _ = future.complete(err) }
      }
      future.release()
    }
  }

  return javaObject
}

public func execWithFuture(_ cl: @Sendable @escaping () async throws -> Void) -> JavaObject {
  guard let javaObject = JCompletableFuture__class?.create() else {
    fatalError("CompletableFuture class is not available")
  }

  let future = JCompletableFuture(javaObject)

  Task.detached {
    let res: Result<Void, Error>

    do {
      res = .success(try await cl())
    } catch {
      res = .failure(error)
    }

    await MainActor.run {
      switch res {
        case .success(let val): _ = future.complete()
        case .failure(let err): withLocalFrame { _ = future.complete(err) }
      }
      future.release()
    }
  }

  return javaObject
}


private func withLocalFrame<R>(_ body: () -> R) -> R {
  let pushed = jni.PushLocalFrame(16) >= 0
  defer { if pushed { jni.PopLocalFrame() } }
  return body()
}

private let JCompletableFuture__class = JClass(fqn: "java/util/concurrent/CompletableFuture")
