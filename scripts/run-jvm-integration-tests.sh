#!/usr/bin/env bash
# Runs the bridge against a real JVM: builds the fixture dylib, generates its
# Java peers, compiles them, and executes Tests/JvmIntegration.
#
# This is the only check that exercises RegisterNatives and the borrow
# semantics. `swift test` covers the generation rules and Swift4jFixtures
# type-checks the expansions, but neither loads a JVM.
#
# Needs a JDK. macOS/Linux host; nothing Android-specific.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

out="$root/.build/jvm-integration"
classes="$out/classes"
java_src="$out/java"

if [ -z "${JAVA_HOME:-}" ]; then
    JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null || true)
fi
if [ -z "$JAVA_HOME" ] || [ ! -x "$JAVA_HOME/bin/javac" ]; then
    echo "no JDK found; set JAVA_HOME" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$classes" "$java_src"

echo "==> building fixture dylib"
# SwiftPM does not reliably rebuild a target when only the macro plugin that
# expands it changed, which silently leaves the dylib expanded from stale
# codegen — the run then tests the previous macro. Touching the sources forces
# re-expansion. Cheaper and safer than deleting build products.
touch "$root"/Sources/Swift4jFixtures/*.swift
swift build --product Swift4jFixtures
swift build --product swift4j-cli

libdir="$root/.build/debug"
[ -f "$libdir/libSwift4jFixtures.dylib" ] || [ -f "$libdir/libSwift4jFixtures.so" ] || {
    echo "fixture dylib not produced" >&2
    exit 1
}

# The macro derives the Java package from the Swift module name, so the CLI
# must be told the same one or the class_init native will not resolve by its
# mangled JNI symbol and class loading fails.
echo "==> generating Java peers"
"$libdir/swift4j-cli" \
    -o "$java_src" \
    --package Swift4jFixtures \
    "$root"/Sources/Swift4jFixtures/*.swift

# The generated peers annotate optionals with org.jetbrains.annotations, which
# ships with the IDE/Android toolchain and not with a bare JDK. Stub the two
# that are referenced rather than pulling in a dependency for a compile check.
stubs="$out/stubs/org/jetbrains/annotations"
mkdir -p "$stubs"
for ann in Nullable NotNull; do
    cat > "$stubs/$ann.java" <<EOF
package org.jetbrains.annotations;
import java.lang.annotation.*;
@Retention(RetentionPolicy.CLASS)
@Target({ElementType.METHOD, ElementType.FIELD, ElementType.PARAMETER, ElementType.TYPE_USE})
public @interface $ann { }
EOF
done

echo "==> compiling Java"
# The generated peers live in a directory literally named after the package, so
# point javac at the sources rather than guessing a layout.
# swift4j emits Kotlin, not Java, for payload enums (a sealed class per case),
# so the generated peer set is mixed-language. This harness is javac-only, so
# those are skipped and reported rather than silently dropped.
kt_count=$(find "$java_src" -name '*.kt' | wc -l | tr -d ' ')
if [ "$kt_count" != "0" ]; then
    echo "    skipping $kt_count Kotlin peer(s); javac cannot compile them:"
    find "$java_src" -name '*.kt' -exec basename {} \; | sed 's/^/      /'
fi

find "$java_src" -name '*.java' > "$out/sources.txt"
find "$out/stubs" -name '*.java' >> "$out/sources.txt"
find "$root/Sources/Swift4j/java" -name '*.java' >> "$out/sources.txt"
echo "$root/Tests/JvmIntegration/BridgeIntegrationTest.java" >> "$out/sources.txt"

"$JAVA_HOME/bin/javac" -nowarn -d "$classes" @"$out/sources.txt"

echo "==> running"
"$JAVA_HOME/bin/java" \
    -Djava.library.path="$libdir" \
    -cp "$classes" \
    BridgeIntegrationTest
