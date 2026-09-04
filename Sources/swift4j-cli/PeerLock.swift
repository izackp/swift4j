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
///   - Methods taking a closure. Java code runs inside the native call, where
///     it can take a JVM monitor and deadlock against a thread blocked here.
///
/// `unsafeWith*` scopes ARE guarded, in `VarGenerator`, but by holding the
/// monitor across the callback rather than for one call — the scope hands out
/// an interior pointer into the owner and a concurrent write corrupts it no
/// matter how the individual view accesses are locked. That carries the same
/// deadlock exposure as a closure-taking method, and is accepted only because
/// a scope is contracted to small reads and writes. A blocking acquire was
/// chosen over a try-lock because the cycle needs an ordinary getter to block,
/// and a getter cannot be allowed to fail fast.
///   - `static` members. There is no instance, so there is no monitor.
///   - `equals` / `hashCode`. Locking two peers in argument order deadlocks
///     against the reversed call.
///   - Swift-side mutation of a bridged `class` while the JVM reads it.
///     Nothing on this side of the bridge is involved in that access.
///   - `async` methods. The call that launches the task is guarded; the work
///     it does after returning is not.
/// The `sealed` half is a second, unrelated guard that shares the same monitor.
///
/// While an `unsafeWith` scope is open, Swift holds an exclusive access to the
/// owner's storage. Reading it back through an ordinary accessor is a conflict,
/// and in the array case `withUnsafeMutableBufferPointer` has moved the buffer
/// out entirely, so the read is undefined rather than merely stale.
///
/// Swift's own dynamic exclusivity enforcement catches exactly this — but only
/// for accesses it can track. Every value here lives in a malloc'd box reached
/// through `UnsafeMutablePointer.pointee`, which is not instrumented: the same
/// re-entrant read runs to completion with no trap and no diagnostic. So the
/// check has to be made here.
///
/// Deterministic on caller code, not timing-dependent, which is the R8 line the
/// nesting guard already sits on.
enum PeerLock {
  static func guarded(_ statement: String,
                      locked: Bool,
                      sealed: Bool = false,
                      owner: String = "") -> String {
    guardedBlock("      " + statement, locked: locked, sealed: sealed, owner: owner)
  }

  /// As `guarded`, for a body that is already indented and may be several
  /// statements.
  static func guardedBlock(_ body: String,
                           locked: Bool,
                           sealed: Bool = false,
                           owner: String = "") -> String {
    guard locked else {
      return body.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("      ") ? String($0.dropFirst(2)) : String($0) }
        .joined(separator: "\n")
    }

    let seal = sealed
      ? "      if (_inScope) {\n"
        + "        throw new IllegalStateException(\n"
        + "          \"\(owner) is inside an unsafeWith scope; the callback may only touch the view\");\n"
        + "      }\n"
      : ""

    return "    synchronized (_ptr) {\n" + seal + body + "\n    }"
  }
}
