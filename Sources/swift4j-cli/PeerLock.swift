/// Serialises bridge access to one peer's Swift storage.
///
/// Reading a refcounted field is `load` then `retain`, and writing one is
/// `release` then `store`. Neither pair is atomic, so a reader on one thread
/// can load a pointer that a writer on another releases to zero before the
/// reader retains it. The result is a retain of freed memory — SIGSEGV, not a
/// wrong answer. Swift normally prevents this with exclusivity enforcement;
/// the bridge hands out a raw pointer and steps around it.
///
/// The monitor is the peer's own `SwiftPtr`, which already exists per peer, so
/// this costs no allocation and one uncontended monitor per crossing.
///
/// What it does NOT cover, deliberately:
///
///   - `unsafeWith*` scopes. The scope holds an interior pointer into the
///     owner for its whole duration, so exclusivity would have to span the
///     callback — and arbitrary Java runs there, which can take JVM monitors
///     and deadlock against a thread holding this one. The `unsafe` prefix is
///     the contract: callers serialise their own scopes.
///   - Methods taking a closure, for the same reason.
///   - `static` members. There is no instance, so there is no monitor.
///   - `equals` / `hashCode`. Locking two peers in argument order deadlocks
///     against the reversed call.
///   - Swift-side mutation of a bridged `class` while the JVM reads it.
///     Nothing on this side of the bridge is involved in that access.
///   - `async` methods. The call that launches the task is guarded; the work
///     it does after returning is not.
enum PeerLock {
  static func guarded(_ statement: String, locked: Bool) -> String {
    guard locked else { return "    " + statement }
    return "    synchronized (_ptr) {\n      " + statement + "\n    }"
  }
}
