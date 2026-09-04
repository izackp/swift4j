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

# swift4j emits Kotlin, not Java, for payload enums (a sealed class per case),
# so the generated peer set is mixed-language and Kotlin has to compile first —
# the Java peers reference the sealed class.
#
# No kotlinc on PATH here, so fall back to the compiler jars that ship inside
# Android Studio. Without either, the Kotlin peers and their tests are skipped
# and said so, rather than silently dropped.
AS_KOTLIN="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/lib"
kotlin_ok=0
if command -v kotlinc >/dev/null 2>&1; then
    kotlin_ok=1
    kotlinc_cmd() { kotlinc "$@"; }
    KOTLIN_STDLIB=$(dirname "$(command -v kotlinc)")/../lib/kotlin-stdlib.jar
elif [ -f "$AS_KOTLIN/kotlin-compiler.jar" ]; then
    kotlin_ok=1
    KOTLIN_STDLIB="$AS_KOTLIN/kotlin-stdlib.jar"
    kotlinc_cmd() {
        "$JAVA_HOME/bin/java" \
            -cp "$AS_KOTLIN/kotlin-compiler.jar:$AS_KOTLIN/kotlin-stdlib.jar:$AS_KOTLIN/annotations-13.0.jar" \
            org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
    }
fi

find "$java_src" -name '*.kt' > "$out/kt-sources.txt"
kt_count=$(wc -l < "$out/kt-sources.txt" | tr -d ' ')

if [ "$kt_count" != "0" ] && [ "$kotlin_ok" = "0" ]; then
    echo "    no kotlinc found; skipping $kt_count Kotlin peer(s) and PayloadEnumTest:"
    find "$java_src" -name '*.kt' -exec basename {} \; | sed 's/^/      /'
fi

if [ "$kt_count" != "0" ] && [ "$kotlin_ok" = "1" ]; then
    echo "==> compiling Kotlin peers ($kt_count)"
    # Java sources are passed for resolution only; kotlinc does not emit for them.
    kotlinc_cmd -nowarn -d "$classes" \
        @"$out/kt-sources.txt" \
        "$root/Tests/JvmIntegration/PayloadEnumTest.kt" \
        $(find "$java_src" -name '*.java') \
        $(find "$root/Sources/Swift4j/java" -name '*.java') \
        "$stubs"/*.java
fi

echo "==> compiling Java"
find "$java_src" -name '*.java' > "$out/sources.txt"
find "$out/stubs" -name '*.java' >> "$out/sources.txt"
find "$root/Sources/Swift4j/java" -name '*.java' >> "$out/sources.txt"
echo "$root/Tests/JvmIntegration/BridgeIntegrationTest.java" >> "$out/sources.txt"
echo "$root/Tests/JvmIntegration/DangerTest.java" >> "$out/sources.txt"

"$JAVA_HOME/bin/javac" -nowarn -cp "$classes" -d "$classes" @"$out/sources.txt"

runtime_cp="$classes"
[ "$kotlin_ok" = "1" ] && [ -f "$KOTLIN_STDLIB" ] && runtime_cp="$classes:$KOTLIN_STDLIB"

# Every suite runs even when an earlier one fails: a known defect must not hide
# a regression in a later section.
status=0

echo "==> running"
"$JAVA_HOME/bin/java" \
    -Djava.library.path="$libdir" \
    -cp "$runtime_cp" \
    BridgeIntegrationTest || status=1

if [ "$kt_count" != "0" ] && [ "$kotlin_ok" = "1" ]; then
    "$JAVA_HOME/bin/java" \
        -Djava.library.path="$libdir" \
        -cp "$runtime_cp" \
        PayloadEnumTest || status=1
fi

# Memory-safety hazards. These can take the JVM down rather than fail an
# assertion — a Java data race yields a wrong value, a race on Swift storage
# yields SIGSEGV — so each runs in its own process and is reported by how it
# died. A clean run is not proof of safety; these are probabilistic.
echo
echo "==> dangers"
for scenario in race escape; do
    echo "  $scenario:"
    set +e
    # A crash here is expected, so keep the JVM's dump out of the repo root and
    # inside the build dir, which the next run clears.
    "$JAVA_HOME/bin/java" \
        -XX:ErrorFile="$out/hs_err_%p.log" \
        -Djava.library.path="$libdir" \
        -cp "$runtime_cp" \
        DangerTest "$scenario" 2>&1 | sed 's/^/  /'
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -gt 128 ]; then
        echo "    CRASHED with signal $((rc - 128)) -- hazard demonstrated"
        status=1
    elif [ "$rc" != "0" ]; then
        echo "    exited $rc -- hazard demonstrated"
        status=1
    fi
done

exit $status
