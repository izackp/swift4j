# swift4j lint checks

One rule: **DiscardedSwiftWrite**.

A getter for a bridged value type returns a *copy* of Swift-owned storage.
Writing to that copy without keeping it means the write goes nowhere — the copy
is unreachable as soon as the expression ends, and Swift never sees it.

```java
box.getLeaf().setLabel("x");         // flagged
box.getLeaf().bump();                // flagged
lossy.getLeaves()[0].setLabel("x");  // flagged

Leaf l = box.getLeaf();
l.setLabel("x");                     // NOT flagged
```

The last one is correct code. `l` is a named copy and the write is visible
through it, exactly as `var l = box.leaf` behaves in Swift. A rule that flagged
it would be worse than no rule.

## How it decides

Nothing heuristic. swift4j marks the generated peers:

- `@SwiftCopyingGetter` — the result is a detached copy. Struct properties,
  optionals, arrays, and `getXAt(int)`. Not primitives, `String`, `Date`, or
  class-typed properties: none of those has a mutation that could be lost.
- `@SwiftMutating` — every setter, and any method Swift declares `mutating`.
  Non-mutating methods are deliberately unmarked; calling one on a temporary is
  harmless.

The detector flags a `@SwiftMutating` call whose receiver is an **unbound**
`@SwiftCopyingGetter` call, seeing through parentheses and array indexing. That
is pure syntax — no dataflow — which is why binding to a variable is exempt
without any analysis.

## Wiring it in

```groovy
// settings.gradle
include ':lint-checks'
project(':lint-checks').projectDir = new File('path/to/swift4j/lint')

// app/build.gradle
dependencies {
  lintChecks project(':lint-checks')
}
```

`lintVersion` must be set to match the Android Gradle Plugin in use.

## Status

Verified against Android Lint 31.13.0: all seven cases pass, including the
bound-copy case that must stay clean.

Each guard was checked by removing it and confirming a test fails — the
annotation checks, and the array-index unwrap. That found a gap: the original
"unmarked getter" case never reached the copying-getter check, because its
callee was not mutating either, so deleting that check broke nothing. The
`allowsMutationOffAGetterThatDoesNotCopy` case exists to cover it.

The module has no build of its own here. To run the tests, point a Gradle
project at `src/main/java` and `src/test/java` with `lint-api` and
`lint-tests` on the test classpath.
