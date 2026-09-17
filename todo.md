# swift4j — outstanding work

Open items on `claude/jvm-serialized`. Sources: the branch review recorded in
`verification-reports/swift4j-jvm-serialized-review.md` in the iOS monorepo, and
the implementation pass of 2026-09-16 (commits `bb1c7d9`..`00d2fbf`).

Verdicts below are the owner's. Items marked LEAVE / IGNORE there are not
repeated here.


## 1. Support extension-declared members (review #10) — BLOCKED, needs design

**Approved, not started.** An earlier pass stopped here rather than improvise:
this is an architecture change, not a fix.

### What is broken

Two different programs generate the two halves of every bridged method, and they
do not see the same source:

- The **CLI** reads every input file, so it sees a type's extensions. It emits
  the Java half: `public native void b();`
- The **`@jvm` macro** is attached to one declaration and can only read what is
  inside those braces. It emits the Swift half: the C thunk, plus the entry in
  the array passed to `RegisterNatives` at class-init.

```swift
@jvm class Foo {
    func a() { }     // macro sees this
}

extension Foo {
    func b() { }     // macro cannot see this
}
```

Both halves are required: `native void b()` is only a promise that a C function
exists; `RegisterNatives` is what fulfils it. The failure modes are asymmetric
and both bad — a declared-but-unregistered method throws `UnsatisfiedLinkError`
whenever it is called (possibly never), while a registered-but-undeclared one
makes `RegisterNatives` reject the **whole batch**, unbinding every native on the
class and surfacing as an error naming whichever method was called first.

Commit `a301492` resolved this by having the CLI **stop emitting** Java for
extension members. Safe, and the reason Kotlin call sites that referenced such a
member stopped compiling. Reversing that is this item.

### Why `@jvm_exported` is not already the answer

It is a `PeerMacro` attached to the member itself, so it runs from inside the
extension where the declaration is visible. Right idea; two things block it.

**A. It cannot identify the type it is extending.**
`Commons.swift:30` resolves the enclosing type as
`lexicalContext.first?.asProtocol(DeclSyntaxProtocol.self) as? (any JvmTypeDeclSyntax)`.
For a member inside `extension Foo { … }` the lexical parent is an
`ExtensionDeclSyntax`, which is not a `JvmTypeDeclSyntax`, so the cast yields
`nil` and `JvmExportedMacro.swift:21`'s guard throws
*"can only be applied to a variable declaration inside an @jvm exported type"*.

The macro can read the *text* `Foo`. It cannot reach Foo's declaration — so it
cannot know whether Foo is `@jvm` at all, whether it is serialized, or what its
Java package and binary name are. The thunk needs all three.

Related to review #5 but **not the same bug**: #5 is "the member block is
stripped, so member-iterating gates answer vacuously". This is "there is no type
declaration here at all". Fixing #5 alone does not unblock this.

**B. Nothing would register the thunk even if it were generated.**
`expandCreateNativeMethodsDefault` builds the `RegisterNatives` array from
`exportedDecls` of the declaration `@jvm` is attached to. An extension member is
not in that list, and the macro building the list still cannot see the
extension. The thunk would be emitted and never bound — the original
`UnsatisfiedLinkError`, now also tripping the mismatch warning added in
`fa0384a`.

### Candidate designs

The architecture assumes one place knows the complete member list. Nothing does.

1. **Self-registering thunks.** Each thunk adds itself to a runtime registry at
   load; `RegisterNatives` is called once from the accumulated set. Extensions
   stop being a special case. Largest change, cleanest end state.
2. **Move registration to the CLI.** It is the side that reads every file. It
   emits the registration list; the macro consumes it. Puts authority where the
   information is.
3. **Make `@jvm_exported` self-sufficient** — e.g. `@jvm_exported(Foo.self)`, so
   no lexical lookup is needed, and have it emit a self-registering thunk.
   Smallest change; shifts the burden to whoever writes the extension.

### Before starting

Get the actual work-list rather than guessing at scope: run the CLI over
`SwiftBridge` + `CaptureAPI` and read the `skipped extension member` lines from
`noteSkippedExtensionMember` (`Sources/swift4j-cli/TypeGenerator.swift:43-45`).
That is the set of members currently missing from the Java surface.

`skippedExtensionMembers` (`TypeGenerator.swift:41`) is currently written and
never read; it is deliberately **held, not deleted**, for this purpose.


## 2. Integration tests have not been run since the 2026-09-16 pass

`./scripts/run-jvm-integration-tests.sh` was not run — it is slow and needs
explicit go-ahead.

This matters more than usual: `#1`, `#3`, `#4` and `#14` all changed runtime
registration, descriptors, or class-init behaviour, and unit tests do not
exercise `RegisterNatives`. Worth green before this fork is re-pinned into the
monorepo.

Unit state at `00d2fbf`: `swift build` clean, `swift test` 76/76 (was 77 — the
dropped one is the duplication-pinning test deleted in `f5a4ba3`).


## 3. Readonly marshalled property is still assigned unvalidated (from #1)

`f222f1e` made the public generated constructor write an
`@jvm(as:toJava:toSwift:)` property through its checked setter. A `let`
(readonly) marshalled property has no checked setter, so that combination is
still stored raw.

Left deliberately: the combination is **already broken independently** — the
macro resolves a `_set<X>` id that the CLI never emits for a readonly property.
Fixing it properly means either emitting a validating native for readonly
marshalled properties, or rejecting the combination with a diagnostic.


## 4. Generated-constructor shape from #1 wants a review

Two Java constructors cannot share a parameter list, so "checked public plus
unchecked package-private" was not expressible as specified. The implemented
shape (`Sources/swift4j-cli/ClassGenerator.swift:116-141`):

```java
public Opaque(String raw) { setRawImpl(raw); }          // checked
       Opaque(String raw, boolean __unchecked) { ... }  // marshal path
```

The public constructor is unchanged for callers; the unchecked overload is
package-private and distinguished only by the trailing flag. Validation reuses
the existing `set<X>Impl` native, so no new native is registered and the
`RegisterNatives` surface is unchanged.

Reasonable, but it is a generated-API shape that no one has reviewed on its
merits rather than as a workaround.


## 5. Review #5 remains IGNORE

`@jvm_exported`'s gates evaluate against a stripped member block, so
`serializedSupportsMutation` and `isSerializedReconstructible` answer vacuously
true when reached through `context.enclosingDeclType`.

Owner's verdict: **ignore for now.** Cost today is one bad error message
(`has no member 'updateJavaObject'` instead of the written diagnostic). Listed
here only because item 1 above will force it to be revisited — note that fixing
#5 is *necessary but not sufficient* for extension support.


## Notes for whoever picks this up

- This repo's `commit-msg` hook **rejects** a bracketed project prefix
  (`[swift4j] …`). Subjects are bare. Footer is `Automated-By: <model name>`.
- Do not re-pin `Package.resolved` in the monorepo as part of swift4j work —
  that is a separate, deliberate step.


## 6. A payload enum's handle still reports the fallback size

`@jvm(nativeBytes:)` is refused on an enum, because `EnumGenerator`'s peer
declares no `__nativeBytes` field to write. That is honest — the argument would
otherwise read as applied while changing nothing — but it leaves a real gap: a
payload enum *is* pointer-backed (`sealed class E(protected val ptr: SwiftPtr)`),
so every instance reports `SwiftPtr`'s nominal default no matter what it holds.

In CaptureAPI that is `JSONValue` and `FilterValue`, both of which can carry a
string or a nested collection.

The fix is the same shape as for a class: declare the field in the Kotlin peer,
have the macro write it at class-init, and lift the refusal. A simple
raw-value enum is unaffected — it crosses as an ordinal and has no handle.
