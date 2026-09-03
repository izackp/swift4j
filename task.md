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
