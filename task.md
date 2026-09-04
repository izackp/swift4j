# swift4j bridge: allocation + borrow semantics

Design record. Decisions, the reasoning behind them, the alternatives rejected,
and what was discovered in the code along the way.


## Goal

Cut allocation in the JVM bridge without breaking Swift value semantics, and
remove the complexity `@jvmBorrowed` introduced.

Origin: 32-bit Android performance — slow sync, UI lockups. That investigation
found the bridge allocating per *property read*. Scope here is swift4j API
design only; app-side fixes (ViewModel projection, `recompute` off Main) are
tracked separately.


## Cost of one boxed property read

`subject.server_data.lastName`, before any change:

- 3 JNI calls
- 2 mallocs, 2 full struct copies
- ~80 retain/release. `Server.Subject` has ~43 mostly-`String?` fields.
- 2 Java objects
- 2 `PhantomReference` + `ConcurrentHashMap` registrations

Measured impact at n=500 in a sort comparator: ~36k boxes per recompute,
~70 forced `System.gc()` calls via the 512-handle watermark.

Swift itself does none of this: `struct_element_addr` twice, then one
`load [copy]` of the `String`.


## Why the bridge copies at all

The asymmetry that causes everything else. Kotlin never copies on property
access because there is nothing to copy — the object already exists on the
heap and the field holds a pointer to it.

Swift structs are laid out **inline**:

    Kotlin   FullSubject -> Subject -> Server.Subject     3 allocations, 2 pointer loads
    Swift    [ FullSubject: [ Subject: [ Server.Subject ] jobName image ] ]   1 allocation

So when Kotlin asks for `current.subject` there is no object to return a
pointer to. One does not exist. The bridge manufactures one: malloc, copy the
bytes in, wrap it.

Not optimisable away — the malloc is native and its address escapes into JNI,
so JIT escape analysis cannot see it.

Every language with value types solved this with some form of address-return:
Swift `_modify` coroutines, C# `ref` returns, Java Project Valhalla (unshipped,
irrelevant on Android). Java has none of it, which is why borrowing has to be
hand-built.


## The three copy sites

**Copy 1 — boxing.** `allocate(capacity: 1)` + `initialize(to: self)`.

- Irreducible. A struct returned by value has no address; the malloc
  materialises it rather than duplicating something Java could point at.
- But it is a *copy* where a *move* would do. `self` is borrowed, so
  `initialize(to:)` retains every refcounted field (~43 for `Server.Subject`).
- Fix: `consuming` variant. 43 retain/release -> 0.

**Copy 2 — property reads.** Root malloc -> second malloc, per nested read,
plus a Java object and a reaper registration.

- Pure waste. This is the one the whole design is about.

**Copy 3 — parameter passing.** `JvmValueTypeDeclSyntax.swift:63`:

    public static func fromJavaObject(_ obj: JavaObject?) -> Self {
      return _self(obj).pointee        // full struct copy, every call
    }

- Every `@jvm` struct parameter, every call. Ranks alongside list marshalling.
- `inout` already avoids it via the closure form
  (`IdentifierTypeSyntax.swift:118`): `T.fromJavaObject(obj) { &$0.pointee }`.
- Fix: **delete the `-> Self` overload.** Every remaining copying site becomes
  a compile error. Covers parameters, receivers, init args, array and dict
  elements, callback args — no per-case rule.
- Needs the bridged Swift declaration to take `borrowing` so the access is
  `load_borrow`, not `load [copy]`. **Not verified.**


## Design restrictions

**R1. Macros cannot do semantic lookup.** The macro sees `var x: Foo` as bare
syntax. **Overstated as a blocker** — see Discoveries. Generated code is
type-checked, so overload resolution can pick a path at compile time, and
`swift4j-cli`'s `TypeRegistry` indexes every `@jvm` type across all input
files. The residual constraint is R2 + R3, not R1.

**R2. `RegisterNatives` fails the whole batch if any Java method is missing.**
Both generators must emit identical native sets from identical rules.

**R3. A `@convention(c)` thunk's return type is static.** `JavaLong` vs
`JavaObject?` cannot be decided at runtime.

**R4. Java has no scoped access or lifetimes.** **Revised — this is the pivot
of the whole design.** Java has no *implicit* scope, but a closure IS a scope.
`unsafeWith { }` gives the bridge exactly the bracket Swift's `_modify` needs.
Everything below follows from noticing this.

**R5. `reachabilityFence` is API 28+**, above minSdk.

**R6. Swift value semantics: `var x = foo.bar` is a copy.** A borrow is only
sound where it is indistinguishable from one, or where the caller has
explicitly opted out.

**R7. Generated classes already require `-keep ... { *; }`**, because Swift
calls `_ptr` and `fromPtr` by JNI name.

**R8. No runtime exception for incorrect code.** A rule that only fires at
runtime is not a rule. Do not add a thrown exception to enforce a bridge
invariant unless it is unreachable no matter how wrong the calling code is. If
wrong Kotlin can reach it, make it not compile, or make it do the right thing.


## Decisions

**D1. Revert `@jvmBorrowed`.** Attribute, macro, guards, CLI branch, `_owner`,
`fromBorrowedPtr` all deleted. Audit says nothing depends on the write-through
it introduced, so reverting is safe and puts the app back on semantics we
understand.

**D2. Scoped borrows via `unsafeWith { }`.** The lambda parameter is a live
pointer into the owner's storage, valid only for the call. The developer owns
the lifetime; escaping it is their responsibility.

Naming *is* the contract, and this is why it does not violate R8: R8 forbids
*enforcing* an invariant with a runtime throw. `unsafeWith` does not enforce,
it documents. Precedent: `withUnsafeMutablePointer`, `unsafeBitCast`,
`sun.misc.Unsafe`.

**D3. Direct leaf accessors for reads.** `list.lastNameAt(i)` — one JNI call,
no allocation, no closure. Generated per scalar leaf of the element type;
bounded by field count, not combinatorial.

Naming split, which is the entire safety story:

    fs.unsafeWith { ... }        // yields a borrow — caller owns the lifetime
    list.unsafeForEach { ... }   // yields a borrow per iteration
    list.lastNameAt(i)           // returns a value — safe
    subject.copy()               // returns an owned box — safe

**D4. Generate `copy()` on every `@jvm` value type.** Replaces the hand-written
per-type workaround (see Discoveries).

**D5. Struct = snapshot, class = shared model.** Chosen per type exactly as in
pure Swift. Already supported; needs documenting, not building.

**D6. Remove `close()`.** No callers anywhere, and it is the only path that
frees a box while a borrow into it is reachable. Drops `AutoCloseable`,
`Reaper.unregister`, `isClosed()`, and the `IllegalStateException` in `get()` —
which R8 wanted gone anyway.

**D7. Keep the cached `fromPtr` / `valueOf` jmethodIDs.** Unrelated to
borrowing, pure win, and verified sound (see Discoveries).


## Rejected alternatives, and why

**`@jvmBorrowed` as shipped.** Opt-in, misusable, covers 3 properties, and the
annotation exists only to work around R1/R2/R3.

**Borrow-by-default with a strong `_owner` field.** Fails on retention: a
borrowed child pins its whole parent. For a struct field the ratio is bounded
and arguably correct — a view keeps what it views. For an array element it is
`n`: hold 1 of 500, keep 500. The governing convention would be "borrow to
read, copy to keep", which Kotlin cannot express, cannot check, and fails
silently. Not a contract.

Also: `_owner` is written and never read, so R8 (proguard) can strip it, and
then the borrow stops holding the root at all. Kept alive today only by the
`-keep ... { *; }` rule R7 already requires — one config change from a
use-after-free.

**Copy-on-write on the borrow.** Reads borrow, first write materialises a copy.
Matches Swift exactly and satisfies R8 with no exceptions. Rejected because it
still leaves no way to edit the owner (Kotlin cannot express a chained lvalue,
R4-as-originally-stated), and it needs `_ptr` to become mutable plus a story
for two threads racing to materialise.

**Full reference semantics on the Java side.** Writes always land; `copy()` is
the escape hatch. Attractive — dissolves the setter, `mutating`, and
no-way-to-edit gaps outright. Rejected because it inherits the same unbounded
retention problem as `_owner`, and it silently changes the meaning of existing
Kotlin in the direction of writes that used to vanish now landing.

**Read-only twin type per struct.** Compile-time safe. Rejected: type
explosion.

**Rejecting setters on a borrow at runtime.** Direct R8 violation — whether an
instance is a borrow is per-instance, so `x.setName(...)` compiles either way
and throws only sometimes.

**Converting the models to classes.** Would remove most of the cost:
`jref.from(self)` caches the peer, so nested access allocates nothing after the
first. Rejected because the cost relocates into shared Swift consumed by three
iOS apps — value semantics gone on iOS, `Sendable` becomes `@unchecked`, GRDB
row models are idiomatically structs, cross-runtime cycles become possible,
`JObjectRef` carries an inline `pthread_mutex_t` so 500 rows means 500 mutexes,
and the whole type tree would have to convert (a struct field of a class still
cannot be borrowed).

The reframe that settles it: **the box already is a class.** A malloc holding a
struct, owned by a Java wrapper, freed by a reaper, is a hand-rolled reference
cell. The bug is not structs-vs-classes — it is allocating a *new* cell on
every read instead of pointing into the one we have.

**Zero-copy array via escaping `withUnsafeBufferPointer`.** UB by contract. Not
an option at any speed, and not recorded as a tradeoff.

**Keeping the `jlong` return.** Blocked by R3 + R2, not R1. Possibly
recoverable: emit both natives unconditionally (`getXPtrImpl -> jlong` and
`getXImpl -> jobject`) and let the CLI, which knows the type, choose which the
Java getter calls. Costs one unused native per property. Verify before relying
on it.


## Discoveries

**`copyServerSubject` is an identity function.**
`CaptureAndroid/SwiftBridge/.../StudentSyncBridge.swift:293`:

    public static func copyServerSubject(subject: Server.Subject) -> Server.Subject {
        return subject
    }

Works only because the bridge copies twice — `.pointee` in, malloc out. A Swift
no-op becomes a Java deep copy. Its comment shows the author reasoned about the
semantics and hedged anyway.

It was **redundant when written** (`server_data` returned a copy box then) and
our `@jvmBorrowed` change made it **load-bearing**. Had it not already been
there, the change would have introduced real bugs at
`StudentInfoViewModel.kt:185` and `:220` — check-in writing `sessionStart` into
the displayed model, mark-absent setting `absent` on it. The clean audit below
is clean partly by luck.

This is the strongest argument for the redesign: the semantics are currently
unguessable. A careful engineer could not tell whether `x.y.z = v` writes
through, and paid for insurance.

**Audit of Kotlin usage — clean.**

- Only `CaptureAndroid` uses swift4j. `CaptureQRAndroid` and `DashboardAndroid`
  have no `io.scade` / `SwiftPtr` / `captureapi` references at all.
- Zero Kotlin calls to any `mutating` method (`clearCachedInfo`, `clear`,
  `updateLabels`, `overwriteWithPOD`, `mergeWithStruct`, `finalizeHash`).
- Zero writes to a *nested* value. Every write targets a root:
  `AddStudentScreen.kt:237-267` writes to `newServerSubjectForInsert()`'s
  result; `StudentInfoViewModel.kt:185,220` write to `copyServerSubject()`'s
  result; `JobTestSeed.kt:166-167` same pattern.
- Nested reads are read-only throughout.

**`JClass` promotes to a global ref.** `JClass(fqn:)` -> `JObject.init` ->
`NewGlobalRef`, so the class ref is global and the cached jmethodIDs stay
valid. D7 is sound.

**Classes are already the shared-model mechanism.** `ClassDeclSyntax` boxes
`Unmanaged.passRetained(obj)`; `JObjectRef` caches the Java peer under a
pthread mutex so the same Swift object always maps to the same Java object;
`fromJavaObject` returns the object itself. `@Observable` classes additionally
get `getXWithObservationTracking(ptr, Runnable)`.

**`JObjectRef` caches its peer `weak: true`** — deliberate, and the existing
mitigation for cross-runtime retain cycles (Java peer retains the Swift object;
a Swift object holding a global ref back is invisible to both collectors).
Needs an audit: `from()` returns `jobj.ptr` when `jobj != nil`, but that is a
weak ref which may have been cleared.

**`TypeRegistry` indexes every `@jvm` type across all input files** — exactly
because Swift parses one file at a time. The CLI can resolve pointer-boxedness
by dictionary lookup; the macro cannot. This is what deflates R1.

**Natives are instance methods.** `defaultParamTypes` gives every non-static
thunk `(JNIEnv*, JavaObject?, JavaLong)`, so JNI holds a local reference to the
receiver for the whole call. That is why the root cannot be collected mid-call
despite R5.

**`borrows()` requires a struct** because `MemoryLayout<Self>.offset(of:)` does
not give a class's stored-property offsets, and Swift exposes no portable API
that does (`class_getInstanceVariableOffset` is ObjC/Darwin only).

**`SwiftPtr`: `ref == null` means non-owning.** Borrowed handles use the
one-arg constructor, so `close()` already no-ops on them and `isClosed()` /
the `get()` throw exist only for owned handles.

**`SwiftArray` (`Sources/Java/Bridging/Array.swift`) is dead and broken.** Zero
references, no Java peer, `get` registered as `"(J)Ljava/lang/Object;"` while
`get_jni` takes `(ptr, index)`, old `JNINativeMethod` rather than
`JNINativeMethod2`, an `unsafeBitCast(Int, to: Self.self)` in `fromJavaObject`,
a `passRetained` handle stored in a *weak* `JObject`, and a per-element
`toJavaObject()` in `get_jni`. Rewrite, do not extend.


## Gaps, and how the scoped design handles them

**G1. "Writes land" was not uniform.** Under interior-pointer borrowing,
optionals (`T?` is not laid out as `T`), payload enums, struct fields of a
class, and anything nested through a computed property all fell back to copy
silently — `fs.image?.isDirty = true` compiled and did nothing.

**Closed, and more thoroughly than a compile-error fix would have.** A scoped
borrow needs only an address valid for the call, not a stable interior one, so
Swift can materialise a temporary and write it back:

    guard var img = _self(ptr).image else { return }
    withUnsafeMutablePointer(to: &img) { callJavaClosure($0) }
    _self(ptr).image = img

That is `_modify`. The whole borrowable/not-borrowable taxonomy disappears — no
suppressed setters, no diagnostics, no special cases.

**G2. Holding a child pinned the whole parent.** Closed. Nothing can be held,
so `_owner` is deleted outright. Retention amplification gone; the R8
field-stripping hazard gone with it.

**G3. Array element writes go nowhere.** Partial. Works when the loop is over a
Swift-owned collection. A LiveData emission is inherently a snapshot held
across time, so writes into that still land nowhere. **Open.**

**G4. Mutable list bridging would invalidate element borrows.** Closed —
element borrows cannot outlive an iteration.

**G5. Concurrency.** **Not closed.** `fs.unsafeWith { launch { it.x } }` still
escapes onto another thread.

Not moot on the grounds that plain Kotlin objects race too. A JVM data race is
memory-safe — reference field writes are atomic and GC keeps referents alive,
so racy Kotlin gives wrong answers, never a crash. A race on a Swift struct in
a malloc is not: assigning a refcounted field is `release(old); retain(new)`,
not atomic, so thread B can load the old pointer, thread A can dealloc it, and
B then retains freed memory. `SIGSEGV` in `swift_release`. On armv7 a 64-bit
field can tear outright, and a multi-word struct read certainly can.

Not hypothetical: `StudentsViewModel.recompute()` runs on Main while sibling
`LiveData`s use `withContext(Dispatchers.Default)` over the same objects.
Likely answer is confining a bridged graph to one thread and saying so, rather
than locking.

**G6. Mutable value as a `HashMap` key.** Closed for borrows — they cannot be
stored. Still applies to owned boxes.

**G7 (new). The closure can stash its parameter.** `fs.unsafeWith { escaped = it }`
dangles after return. Java has no lifetime annotations, so this is undetectable
at compile time.

**Accepted, by decision D2.** The `unsafe` prefix is the contract. Note Kotlin
`inline`/`crossinline` does not help — it restricts what you can do with the
*lambda*, not with its parameter.

Optional compile-time nudge, not adopted: have `unsafeWith` yield a distinct
type (`Subject.Borrowed` rather than `Subject`), so `escaped = it` only
compiles when the field is declared as that type — deliberate and greppable
instead of invisible. Costs a second generated type per struct.


## Remaining problems

**`unsafeWith` is hostile to the read hot path.** A comparator becomes
`a.unsafeWith { x -> x.serverData.unsafeWith { sd -> sd.lastName } }`. Each
scope is a JNI down-call *plus* an upcall into the Java lambda: ~4 crossings
per property read, versus 3 today and 1 with interior-pointer borrowing. It
removes the allocations — the real win — but adds upcalls to the path we were
trying to speed up, and it is viral at every nesting level. **This is why D3
exists.** Reads must have a non-closure path.

**G3 and G5 above.**

**Nothing has been measured and nothing has run on a device.** The
`RegisterNatives` binding of `getLocalIdPtrImpl` / `(J)J` is unproven, and its
failure mode is all-or-nothing: one name or signature mismatch unbinds every
native on the class. Builds green does not test this. Moot if D1 lands first,
but the same exposure returns with every new native.

Instruments available: `traceObserver` logs `recompute took Xms main=true`;
`SwiftPtr.liveCount()`, `totalRegistered()`, `totalFreed()`,
`currentWatermark()`.

**Unrelated, still open:** `Array+Util.swift`'s `asyncMap` holds an exclusive
`inout` access across a suspension point.

**Blast radius.** swift4j is a library. These are semantics for every consumer,
not only this monorepo.

**New guards must actually fail the build.** `bridgings()` is called under
`try?` in `expandCreateNativeMethodsDefault`, which silently drops native
registration. `makeBridgingDecls` does surface a hard error (confirmed
empirically) — any new guard needs the same check.


## D2: Option B, as built

Decided: **Option B**. It still needs A's Swift-side mechanism — the macro must
emit code that compiles for every `T`, so the pointer-boxed/fallback split has
to exist regardless. B's contribution is the *Java surface*.

- **Macro** emits `unsafeWith<X>Impl` for every property passing a purely
  syntactic rule (non-static, non-`let`, non-computed; a plain named type that
  is not primitive, `String`, or `Data`; optionals, arrays and dictionaries
  excluded). Body is `_jvmScopedBorrow(&self.x, body)`.
- **CLI** mirrors that rule to *declare* the native — R2 needs the Java method
  to exist for every registered native — but exposes the public
  `unsafeWith<X>` wrapper only where `TypeRegistry` confirms the type is a
  `@jvm` struct.
- **Swift** picks behaviour by overload resolution on `JvmPointerBoxed`:
  conforming types get a real zero-copy view via `withUnsafeMutablePointer` +
  `fromUnownedPtr`; everything else gets convert / call / write-back.

Net effect: `Date`, `URL`, `Result`, `Dictionary` properties get the native
declared with no caller, so nothing generated can reach the fallback. It exists
so the thunk compiles, and behaves correctly rather than trapping if reached.

Verified by running the CLI over CaptureAPI: `FullSubject.unsafeWithSubject`,
`Subject.unsafeWithLocalId`, `Subject.unsafeWithServer_data`,
`Job.unsafeWithServer_data` all exposed; `LocalImage.modifiedAt` and
`Server.Subject.updatedAt` (both `Date`) declare the native with no wrapper.

Residual risk: the syntactic rule is duplicated across two modules
(`VariableDeclSyntax.scopedBorrowable`, `VarGenerator.scopedBorrowable` +
`nonBorrowableNames`). They must not drift — a mismatch unbinds every native on
the class.


## Superseded: the decision that blocked D2

Both generators must emit identical native sets (R2), and the macro cannot do
semantic lookup (R1's true residue). So "which properties get `unsafeWithX`"
has to be answered by a rule both sides can evaluate from syntax alone.

A purely syntactic rule — "non-primitive, non-`String`, non-`Data`" — does not
work. `Date` bridges by **conversion**, not pointer-boxing
(`Date+JConvertible.swift` maps to `java/util/Date` via `getTime`), as do
`URL`, `Result`, and `Dictionary`. None has a `fromUnownedPtr` to call, and
none can. The rule would emit uncompilable Swift for every `Date` property.

Two ways out:

**Option A — uniform natives, behaviour by conformance.** Every non-builtin
property emits `unsafeWithXImpl`, so R2 holds. Swift picks by overload
resolution on a new `JvmPointerBoxed` protocol that `@jvm` / `@jvmBinding`
conform to:

- conforming: real scoped borrow. `withUnsafeMutablePointer(to: &self.x)`,
  wrapped by `fromUnownedPtr`. Zero copy, writes land.
- not conforming: convert with the existing `toJavaObject()`, hand that to the
  body, convert back with `fromJavaObject`, write back. A scoped *copy*, but
  writes still land.

Delivers the G1 uniformity claim in full. Costs a protocol, its conformance in
both macros, two helper overloads in the Java module, and a `SwiftBorrow<T>`
interface.

**Option B — CLI drives, macro emits both.** Macro emits every variant
unconditionally; the CLI, which has `TypeRegistry`, decides which the Java
method calls. Costs unused natives per property. Also the mechanism that would
recover the `jlong` return.

Not picked. A affects semantics for non-boxed types; B trades binary size for
simplicity. Needs a decision before D2 can proceed.


## Status

Done and building clean:

- **D1.** `@jvmBorrowed`, `JvmBorrowedMacro`, `borrows()` in both generators,
  `makeBridgingBorrowedGetter`, `_owner`, `fromBorrowedPtr` all removed.
  `@jvmBorrowed` stripped from `FullSubject.subject`, `Subject.localId`,
  `Subject.server_data`.
- **D4.** `copy()` generated on every `@jvm` value type — Java `copy()` +
  `copyImpl` native, Swift `copy_jni` thunk, registered as `("copyImpl",
  "(J)J")` for value types only. `fromUnownedPtr` added for D2 to build on.
- **D6.** `close()` removed, with `AutoCloseable`, `isClosed()`,
  `Reaper.unregister`, and the `IllegalStateException` in `get()`. `SwiftPtr.ptr`
  is now `final`, and the `PhantomReference` field is gone — the reaper's map
  holds it. No callers existed anywhere.
- **D7.** Cached jmethodIDs kept.

- **D2.** `JvmPointerBoxed` protocol + `_jvmScopedBorrow` overloads
  (`Sources/Java/Base/JvmScopedBorrow.swift`), `SwiftBorrow<T>` Java interface,
  `fromUnownedPtr` / `fromUnownedPointer` on value types, per-property
  `unsafeWith<X>` in both generators. Option B as described above.

Not done: **D3** (excluded by request), `unsafeForEach` for arrays, copy-1 and
copy-3, `copyServerSubject` deletion, and the G3/G5 decisions.

`copyServerSubject` is redundant again now that D1 landed, but leave it until
`copy()` is proven on a device — deleting it is a behaviour change on two
live call sites.

Nothing has been run on Android. Only `swift build` has been verified.


## Pinned defects

`Tests/JvmIntegration/BridgeIntegrationTest.java` asserts these silent losses
so they cannot change unnoticed. **They pass because the bug is present.** A
green run therefore includes four real defects.

- **Plain getter writes are discarded.** `box.getLeaf().setLabel(x)` boxes a
  copy and writes into it. The default path, and the reason `unsafeWith`
  exists — avoidable, not fixed.
- **`mutating` on a nested value is discarded.** `box.getLeaf().bump()` dies
  with the box, while the identical call on an owned root persists. Nothing in
  the Java signature distinguishes the two. Worse than a setter, which at least
  reads as a write.
- **Optional properties have no scoped borrow.** `Optional<T>` is not laid out
  as `T`, so the rule excludes it and there is no scoped alternative to reach
  for. Writes through the getter are lost.
- **Array element writes are lost.** One owned box per element, so a write
  never reaches the array it came from. G3, unresolved.

Not pinned, because a test would be unsafe or unreliable: escaping the borrow
out of `unsafeWith` (undefined behaviour by contract, which is what the
`unsafe` prefix buys), and the concurrency exposure in G5.


## Sequence

1. **D1.** Done.
2. **Measure on device.** Establishes the baseline the rest is judged against.
3. Decide Option A vs B above.
4. **D2 + D4.** `unsafeWith` / `unsafeForEach` scoped borrows. `copy()` done;
   delete `copyServerSubject` once proven.
5. **Copy 3.** Delete `fromJavaObject(_:) -> Self`; fix the compile errors.
6. **Copy 1.** `consuming` boxing variant.
7. **D6.** Done.
8. **D5.** Document struct-vs-class.
9. Decide G3 (list snapshots) and G5 (thread confinement).
10. Audit `JObjectRef`'s weak peer cache. Rewrite `SwiftArray` or delete it.


## G5 resolved: the cross-thread race, and D8

The race is **not** a borrowing problem. `DangerTest` demonstrated it through
`unsafeWith`, which made it look like one. It is not:

    thread A:  box.getTag()          load the tag pointer, then retain it
    thread B:  box.setTag("x")       release the old tag, then store the new

Two plain accessors on one shared peer. B's release can land between A's load
and A's retain, so A retains freed memory. `unsafeWith` is not involved and
neither is any nested struct. Class peers are the worst case, since one Swift
object behind one Java peer is their whole design.

Kotlin does not have this problem. JVM reference writes are atomic and the
collector keeps a referent alive as long as any thread can name it, so a racy
Kotlin program returns a stale value. Racy ARC frees at refcount zero and knows
nothing about a thread that has loaded a pointer but not yet retained it.

Actor isolation would not help either. The thunk is a `@convention(c)` pointer
the JVM calls from whatever thread it likes; there is no executor hop and the
compiler cannot see the call site.

### Why an atomic store is not the fix

The unsafe step is on the *reader* — load and retain are two operations. Any
store-side primitive leaves that window open. What is actually needed is
load+retain as one indivisible step, which comes from either mutual exclusion
or deferred reclamation. Per-field atomicity would also be meaningless for a
struct: `setLabel` then `setCount` is two stores under any scheme.

### Rejected

**Thread confinement.** Stamp the owning thread on the peer, assert it in every
native. Free in release, deterministic in debug. Rejected: the data has to be
reachable from async code.

**Document it.** "Peers are not thread-safe, callers serialise." Costs nothing,
fixes nothing. Same rejection.

**Deferred reclamation.** Hazard pointers or epoch reclamation, so nothing is
freed while a reader might hold it. Correct and lock-free, and it is what the
JVM gives Kotlin for free. Rejected as disproportionate: it is a small garbage
collector underneath ARC.

**A lock held across an `unsafeWith` scope.** Arbitrary Java runs inside the
scope and can take JVM monitors, so a thread holding the Swift lock and wanting
a monitor can deadlock against a thread holding that monitor and wanting the
Swift lock. Neither runtime can see the other's lock graph. Rejected — and it
is unnecessary, see D8's scope rule.

### D8: stripe-locked accessors

Serialise every native call on the **root allocation** it touches.

    getTagImpl(ptr):       lock(root); load + retain; unlock
    setTagImpl(ptr, v):    lock(root); release old + store new; unlock

Properties:

- No user code runs inside the lock, so the span is bounded, non-reentrant,
  and only ever one lock deep. No deadlock is constructible.
- Concurrent access from any thread becomes safe rather than forbidden, which
  is the requirement confinement failed.
- Concurrent readers serialise unnecessarily. Accepted: a reader-writer lock
  would not, but reads here are short enough that the extra state costs more
  than it saves.

**Where the lock lives.** Not in the object. A boxed struct is a bare `malloc`
with no header, and adding one changes `allocate`, `fromPtr`, `deinit`, and
`fromUnownedPtr` together. Instead a striped global table — a fixed number of
locks, index derived from the root pointer. No layout change, no per-object
cost. Unrelated objects can collide on a stripe, which costs contention and
nothing else. Stripe count wants to be a power of two so the index is a mask.

**Cost.** One uncontended lock and unlock per crossing, against a JNI
transition that already costs several times that. Against the 36k reads of a
sort recompute it is well under a millisecond, so it does not reopen the
performance problem this branch exists to fix.

**The scope rule.** `unsafeWith` takes no lock at all. Memory safety only
requires each individual field access to be exclusive; making a whole callback
body atomic is a stronger property nothing here needs. The `Borrowed` view's
forwarding accessors each take the root lock for their own duration, exactly
like a plain accessor. That is what removes the deadlock, and it means the
scope is memory-safe without being transactional — a concurrent writer can
still interleave between two reads inside one scope, and callers get a
consistent snapshot by copying, not by holding a scope.

**What has to be built.** `Borrowed` currently wraps a peer over an *interior*
pointer, so locking on what it holds would key a different stripe from the
root's and exclude nothing. The root pointer has to be threaded through
`_jvmScopedBorrow` and `wrapBorrowed` so the view locks the allocation it
actually lives inside.

Unresolved: what identifies the root for a peer built by `fromPtr` from a
Swift-side return value, where there is no enclosing allocation and the peer is
itself the root.

### D8 as built, and where the spec above was wrong

Two things changed on contact with the code.

**The lock is a per-peer Java monitor, not a striped Swift table.** Every peer
already owns a `SwiftPtr`, so `synchronized (_ptr)` costs no allocation and
needs no stripe index. More importantly it lives entirely in generated Java:
no macro change, no native signature change, and so no `RegisterNatives`
exposure. The striped table was solving a problem — keying an interior pointer
back to its root — that disappears once the lock is on the peer.

**The scope rule was backwards.** The spec had `unsafeWith` take no lock while
the `Borrowed` view's accessors each took one. That is unsound. The scope holds
an interior pointer into the owner for its entire duration, so a concurrent
`setLeaf` corrupts it no matter how the individual view accesses are guarded.
Per-access exclusion inside the scope buys nothing and would advertise a safety
it does not provide, so `Borrowed` forwards unguarded and `unsafeWith` stays
caller-serialised — which is what the `unsafe` prefix already promised.

The deadlock reasoning survives: holding the lock across the callback is the
only thing that would make scopes safe, and arbitrary Java runs in there.
Methods taking a closure are excluded for the same reason.

Also excluded, each for its own reason: `static` members (no instance to lock),
`equals` / `hashCode` (locking two peers in argument order deadlocks against
the reversed call), `async` methods (the launch is guarded, the work it does
after returning is not), and Swift-side mutation of a bridged class while the
JVM reads it (nothing on this side of the bridge is in that access path).

### Small strings hid the bug

The first `race-root` scenario wrote `"w0"`, `"w1"`, … and survived nine
million *unguarded* iterations. Swift stores a string of up to 15 UTF-8 bytes
inline in the struct, so there was no refcounted buffer to release and no
hazard to hit. Padding the writes past that threshold reproduced the crash in
under a second.

Worth carrying forward: any test of ARC-level races through the bridge has to
force heap storage, or it silently tests nothing. A green run is otherwise
indistinguishable from a fixed bug.

### D8, second pass: scopes are guarded too

The correction above said scopes stay caller-serialised. That was one step
short. `unsafeWith` now holds the owner's monitor for the whole callback.

Per-access locking inside a scope is not enough and never was: the interior
pointer stays live across the callback, so a concurrent `setLeaf` corrupts it
however the individual view reads are guarded. Either the monitor spans the
callback or the scope is unsafe.

A try-lock was considered and rejected. It only prevents scope-versus-scope
contention, and the deadlock cycle does not need two scopes:

    thread A: inside a scope, holds the peer, callback wants monitor M
    thread B: holds M, calls box.getTag(), blocks on the peer

B is an ordinary getter. A getter cannot fail fast, so try-lock leaves the
cycle intact while adding a timing-dependent exception — the worst kind under
R8, since it passes in testing and throws under load.

So the exposure is accepted rather than removed: a scope may deadlock if its
callback takes a Java lock. The contract is that a scope does small reads and
writes, which is what makes that acceptable.

Nesting is separate and is rejected outright. Monitors are reentrant, so
`box.unsafeWithLeaf(a -> box.unsafeWithLeaf(b -> …))` would otherwise be handed
two live views of one storage. An `_inScope` flag on the owner throws instead.
That is deterministic caller error, not a race, which is the R8 distinction:
it cannot pass in testing and fail in production. Scopes on distinct peers
still nest, and the flag is only emitted for types that expose a scope.

`DangerTest` now runs four scenarios, all expected to survive: `race-root`
(plain accessors), `race` (scope versus reader), `escape` (view outliving its
scope), `nest`. Each was verified against a build with its guard removed.


## D9: scoped borrow for optional properties

`var maybe: Leaf?` gets no `unsafeWith`, so the copying getter is the only
access and every write through it is lost. Unlike a plain struct property there
is no alternative to reach for, which is what makes this worse than the pinned
getter defect rather than an instance of it.

The rule excludes it because `Optional<T>` is not laid out as `T`. For a struct
with spare bits the payload often does sit at offset zero, but "often" is not a
layout guarantee and reading it as one is the kind of assumption that survives
testing and fails on another architecture.

So do not point into the optional. Unwrap, borrow the local, write back:

    guard var unwrapped = value else { return }
    withUnsafeMutablePointer(to: &unwrapped) { … }
    value = unwrapped

This is a copy in and a copy out, so it is not a borrow in the strict sense.
It is still the right trade: the cost is one copy per *scope*, not per property
read, and the scope is the deliberate-edit path where a copy was never the
problem. Writes land, which is the whole point.

Semantics: `nil` runs the body zero times, matching `if let`. Whether the Java
wrapper should return a boolean saying whether it ran is open — it costs
nothing and callers otherwise cannot distinguish "absent" from "present and
unchanged".

Both generators need the syntactic rule widened to admit an `OptionalTypeSyntax`
whose wrapped type is itself borrowable, and they must widen identically (R2).
The CLI exposes the public wrapper only where the wrapped type resolves to a
`@jvm` struct, as it already does for the non-optional case.

Carries one hazard that the in-place version does not: the write-back happens
after the body returns, so anything the body does that reads the property back
through the owner sees the stale value. D11 addresses that.


## D10: unsafeForEach for array properties

`var leaves: [Leaf]` boxes an owned copy per element, so an element write never
reaches the array. G3, still open, and again with no alternative to reach for.

Unlike the optional case a real borrow is available:

    self.leaves.withUnsafeMutableBufferPointer { buf in
      for i in buf.indices {
        // hand Java a peer over buf.baseAddress! + i
      }
    }

Zero copy, writes land in place, and element addresses are stable for the
duration. The Java side yields `Leaf.Borrowed` per element, invalidated after
each iteration rather than at the end, so a view cannot outlive its element.

The problem is `withUnsafeMutableBufferPointer`'s own contract: it moves the
buffer out of the array for the duration, and touching the original array
inside the closure is undefined. If the callback calls `box.getLeaves()` this
is UB, not merely wrong — the same class of defect as the escaping-buffer idea
rejected earlier in this document. The difference is that this one is
conditional on re-entry rather than unconditional, which makes it fixable
rather than disqualifying. It is only sound with D11.

Dictionaries are not in scope. Values in a `Dictionary` have no stable
addresses across the call, so there is no equivalent to borrow.


## D11: seal the peer for the duration of a scope

D9 can hand back stale reads and D10 is undefined behaviour, both for the same
reason: the callback can reach the owner through its ordinary accessors while a
scope is open.

`_inScope` already exists and already rejects a nested scope on the same peer.
Extending the same check to the plain accessors closes both:

    synchronized (_ptr) {
      if (_inScope) throw new IllegalStateException(…);
      …
    }

Cost is a boolean read under a monitor already held. The check is deterministic
on caller code, not timing-dependent, which is the R8 line the nesting guard
already sits on — it cannot pass in testing and fail under load.

It does make `box.unsafeWithLeaf(l -> box.getTag())` illegal, which is a real
restriction and will look arbitrary to anyone who has not read this section.
It is the same rule the deadlock exposure already implies: inside a callback,
touch only the view.

Sequence matters. D11 lands first, or D10 ships UB.


## Not planned

The two pinned getter defects stay. `box.getLeaf().setLabel(x)` and
`box.getLeaf().bump()` both write into a copy, and both have `unsafeWith` as a
working alternative. Making the plain getter borrow instead was considered at
length above and rejected: it pins the parent, and memory has to stay low.

The orphaned `HashMap` key stays too. Java's contract already says a mutable
key is undefined, so the bridge is not doing anything wrong. What it lacks is a
way to say so — there is no immutable peer type to offer as a key, and no
warning at the point of insertion.

### D9 corrected: it is a real borrow, verified

The copy-in / write-back design above was wrong, and wrong for a reason worth
keeping: `unsafeWith` exists to avoid the copy, not to make writes land. A
scope that copies in and out is no cheaper than the getter for a read, so it
would have failed at the thing the API is for. "One copy per scope is fine"
was an answer to the wrong question.

Force-unwrap is an lvalue, and `&self.maybe!` addresses the payload in place.
Measured on a stored optional in a struct:

- a write through the pointer reaches the original
- the address is stable across separate borrows
- the payload lies inside the owner's own storage, at offset 0 here

So D9 is a genuine borrow with no copy on either side, the same as the
non-optional case. `nil` still needs a guard first, since force-unwrapping it
traps.

### Re-entrancy is silent through the bridge, which is why D11 is required

Reading the owner while a scope is open traps under Swift's dynamic
exclusivity enforcement — "Simultaneous accesses … modification requires
exclusive access" — for both the optional borrow and the array buffer. That
sounds like the language already covers this.

It does not. Enforcement applies to accesses Swift can track. The bridge holds
every value in a malloc'd box reached only through
`UnsafeMutablePointer.pointee`, and that path is not instrumented. The same two
re-entrant reads, through a pointer instead of a variable, ran to completion
with no trap and no diagnostic — including the array case, where the array is
moved out for the duration and reading it is undefined.

So the failure mode through the bridge is silent UB, not a crash. D11 is not
defence in depth; it is the only thing standing between D10 and undefined
behaviour, and it has to land first.


## D9, D10, D11 built

All three landed, in the order the spec required.

**D11** seals a peer's accessors while one of its scopes is open, reusing the
`_inScope` flag and the monitor already held. `DangerTest seal` covers read,
write, and that the seal lifts on the way out.

**D9** borrows an optional's payload through `&value!`. A real borrow, not the
copy the spec first proposed.

**D10** iterates an array's elements through `withUnsafeMutableBufferPointer`,
invalidating each view as its iteration ends.

Every guard was verified against a build with it removed. Removing the peer
lock, the scope monitor, or the buffer borrow reproduces the original fault;
removing `_inScope`, the seal, or the per-element invalidation lets the
corresponding check through.

### What these did not fix

The plain getters still lose writes — `box.getLeaf().setLabel(x)`,
`lossy.getMaybe().setLabel(x)`, `lossy.getLeaves()[0].setLabel(x)`, and
`box.getLeaf().bump()`. Five checks remain pinned. What changed is that every
one of them now has a scope to reach for instead, so none is a dead end.

### Gaps found while building

`Subject!` is not borrowable. It parses as
`ImplicitlyUnwrappedOptionalTypeSyntax`, which the optional branch never sees,
even though the layout is identical to `Subject?`. Both generators exclude it
so R2 is safe; it is a missing feature, not a mismatch.

`T??` is excluded deliberately — there is no single sensible borrow.

Dictionary values remain out of reach. They have no stable address for the
duration of a call, so there is no equivalent to `withUnsafeMutableBufferPointer`
to build on.

A throwing body does not distinguish a borrow from copy-and-write-back, as was
assumed when that check was written. JNI leaves the exception pending and the
thunk runs to the end either way, so both designs store the value. Nothing
observable from Java separates them, which is why the in-place claim rests on
measured addresses rather than on a test.


## The four getter defects: decided

`box.getLeaf().setLabel(x)`, `lossy.getMaybe().setLabel(x)`,
`lossy.getLeaves()[0].setLabel(x)` and `box.getLeaf().bump()` are one defect,
not four: the getter returns an owned copy, so the write lands somewhere
unreachable.

The precise defect is **mutating a temporary**, not mutating a copy. This is
correct code and must stay correct:

    Leaf l = box.getLeaf();
    l.setLabel("x");

`l` is a named copy, the write lands in it, and it is observable through `l` —
exactly what `var l = box.leaf` does in Swift. Only the unbound form is
broken, because the copy is unreachable the moment the expression ends.

That distinction rules out the first idea considered here, an immutable
projection type returned by getters. It would have made all four uncompilable,
but it would also have broken the bound form above and forced a pointless
`copy()` on correct code.

**Decision: keep copy semantics.** The defect is real but narrow, every path
now has a scope to reach for, and the broken spelling is syntactically
detectable.

### Planned: a lint rule rather than an API change

Emit two markers from the generator — `@SwiftCopyingGetter` on the getters,
`@SwiftMutating` on setters and mutating methods — and warn when a
`@SwiftMutating` call has a receiver that is an unbound `@SwiftCopyingGetter`
call, or an array index into one.

No name heuristics and no dataflow: "unbound call expression" is syntax. It
covers all four, including `bump()`, and both escapes are what the diagnostic
should suggest — bind the copy if that was the intent, open a scope if the
owner was.

Android Lint is the target. It sees Kotlin and Java through one UAST detector,
runs in the IDE, and fails `./gradlew lint`. detekt is Kotlin-only and needs
type-resolution mode; Error Prone cannot see Kotlin at all.

Not started. The generator side is small; the `lint-checks` module and its
wiring into CaptureAndroid is the bulk, and that plumbing has not been looked
at yet.

### Not taken: projection handles

`box.getLeaf()` returns a `Leaf` backed by `(owner, accessor)` rather than its
own box, forwarding every operation back through the owner:

    getLabel()     -> box.unsafeWithLeaf(v -> v.getLabel())
    setLabel("x")  -> box.unsafeWithLeaf(v -> v.setLabel("x"))

Same class, same interface, so `box.getLeaf().setLabel(x)` simply works. All
four defects disappear with no annotations, no lint rule and no new type.

It is also the best answer to the performance problem this branch exists for.
A property read today does a Swift `malloc`, a copy, and a Reaper
registration; a handle allocates one small Java object and nothing on the Swift
side. For read-one-field-and-discard — the sort path — it is strictly cheaper.
It loses where several fields are read off one value, which becomes several
JNI crossings instead of one crossing and several local reads.

Rejected because it is reference semantics, and value semantics was already
chosen. It trades the silent-write bug for a stale-snapshot bug:

    Leaf before = box.getLeaf();
    box.setLeaf(other);
    before.getLabel();   // other's label; `before` was never a snapshot

`copy()` becomes the only way to take a snapshot. Also: every `Leaf` would
carry a mode (owned pointer or projection) that every accessor branches on,
chained projections re-enter through the whole chain, and a handle touched
inside an `unsafeWith` on its own owner hits the D11 seal.

Worth revisiting only if measurement shows the boxing on the read path is still
the dominant cost after the current work, and if CaptureAndroid turns out to
read getter results once and discard them rather than holding them as
snapshots. That usage question has not been checked.

### Sharpening why handles diverge

Two objections were raised against handles and only one holds.

The one that does not: "a struct coming from Swift would be mutated in place
despite Swift thinking it is unchanged." It would not. Swift passes a struct by
value, the bridge boxes a copy, and Java mutating that copy is exactly what
Swift semantics prescribe — the caller's value is untouched either way. There
is nothing lost here that Swift would not also lose.

The one that does, stated properly: Swift yields a **copy on every struct
property read**, whether the owner is a struct or a class.

    var l = box.leaf    // a copy, always
    l.label = "x"       // box is untouched

A handle makes that read an alias. So handles would not be mirroring Swift
semantics; they would be diverging from them at the exact point a caller is
most likely to be reasoning in Swift terms. That divergence is uniform across
class and struct roots, so it is not conditional on anything invisible — it is
simply not what the language does.

That is the real cost, and it is the same fact as the stale-snapshot example
above, grounded properly: not "surprising to a Java developer" but "different
from what Swift actually does".


## Projection handles, built on branch claude/projection-handles

Implemented after all, to see what it actually costs. `fixes` is untouched.

A getter for a `@jvm` struct property now returns a peer with no storage of its
own, holding a `SwiftScope` that re-enters its owner. Every operation opens its
own scope, so nothing holds a pointer between operations and the D8 monitor and
D11 seal still apply unchanged.

    public Leaf getLeaf() {
      return Leaf.projection(this::unsafeWithLeafRaw);
    }

The scope moved into a private `Raw` helper, which is what projections re-enter
through and is also what the public `unsafeWith` is built on. `Raw` is itself
projection-aware, which is what makes a chain reach the root:
`mixed.getHolder().getLeaf().setLabel(x)` lands in `mixed`.

Covers all three property shapes. Optionals return a projection when present
and null when absent, with presence taken from the existing scope — it runs
zero times when there is no payload, so that half needed no new native. Arrays
return element projections backed by a new indexed scope; iteration cannot back
a projection, because a projection is re-entered per operation and has to land
on the same element every time.

Two new natives, both registered by the macro and declared by the CLI:
`unsafeElementOf<X>Impl` and `sizeOf<X>Impl`. The size native exists because
taking the length from the copying getter would box the whole array — the exact
cost this design removes.

**All four getter defects report FIXED.** Only the `HashMap` key remains, which
is ignorable. 56 integration checks and 25 unit tests green, and the five
danger scenarios still pass.

### What it cost

`_ptr()` has to materialise. A projection has no address, so handing one to
Swift produces a real box, kept in a field so it outlives the JNI call that
reads it. Fresh per call rather than cached, since the owner may have moved on
and a stale box would be worse than the copy this exists to avoid.

Every accessor now branches on the backing. `equals`, `hashCode` and `copy()`
go through `_ptr()` and therefore materialise, which is correct but means
comparing two projections copies both.

The divergence is pinned as a test rather than left implicit:

    Leaf before = box.getLeaf();
    box.unsafeWithLeaf(l -> l.setLabel("after"));
    before.getLabel();   // "after" — Swift would have given a snapshot

`copy()` is how to take a real snapshot, and that is also pinned.

An element projection outliving its index reads as absent rather than trapping,
since the array may legitimately have shrunk.

### Not measured

Nothing here has been benchmarked. The claim that projections are cheaper on
the read path is still an argument from what the code does — no malloc, no
copy, no Reaper registration — not a measurement. Reading several fields off
one value is several crossings now, and whether that is a net win depends on
CaptureAndroid's access pattern, which has not been checked either.
