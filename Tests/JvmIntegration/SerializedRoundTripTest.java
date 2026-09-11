import Swift4jFixtures.SerializedBridge;
import Swift4jFixtures.SerializedRow;
import Swift4jFixtures.SerializedLeaf;
import Swift4jFixtures.Leaf;

/**
 * Runtime proof for {@code @jvm(serialized: true)}.
 *
 * <p>Compiling the fixtures shows the expansion type-checks. Only running it
 * shows the constructor descriptor matches, the arguments land in the right
 * slots, and the nested conversions work — a reordered argument list produces a
 * peer whose fields are all populated and all wrong, which no compile-time
 * check can see.
 */
public final class SerializedRoundTripTest {

    private static int failures = 0;

    private static void check(String what, Object actual, Object expected) {
        if (actual == null ? expected == null : actual.equals(expected)) {
            System.out.println("  ok     " + what);
        } else {
            System.out.println("  FAIL   " + what + ": expected <" + expected + ">, got <" + actual + ">");
            failures++;
        }
    }

    private static void checkTrue(String what, boolean cond) {
        check(what, cond, true);
    }

    public static void main(String[] args) {
        System.loadLibrary("Swift4jFixtures");

        // ---- Swift -> Java ----
        SerializedRow row = SerializedBridge.makeRow();

        check("id crosses", row.getId(), 42L);
        check("String crosses", row.getName(), "hello");
        check("Date crosses", row.getStamp().getTime(), 1_700_000_000_000L);

        // A computed property is evaluated once, Swift-side, and arrives as a field.
        checkTrue("computed property arrives as a value", row.getFlag());

        // A nested serialized member recursed into its own copy.
        SerializedLeaf inner = row.getSerializedLeaf();
        check("nested serialized label", inner.getLabel(), "inner");
        check("nested serialized weight", inner.getWeight(), 2.5);

        // A nested handle member still boxes a pointer, and still works.
        Leaf handle = row.getHandleLeaf();
        check("nested handle label", handle.getLabel(), "leaf");
        check("nested handle count", handle.getCount(), 7L);

        // ---- null payloads ----
        SerializedRow empty = SerializedBridge.makeRowWithNilName();
        check("nil Optional arrives as null", empty.getName(), null);
        checkTrue("false computed property", !empty.getFlag());

        // ---- Java -> Swift ----
        // Renders what Swift received, so a field in the wrong slot shows up as
        // a wrong value rather than as a bare inequality.
        check("round-trip preserves every field",
              SerializedBridge.describe(row),
              "id=42 name=hello stamp=1700000000 handleLeaf=leaf:7 serializedLeaf=inner:2.5 flag=true");

        check("round-trip preserves a null Optional",
              SerializedBridge.describe(empty),
              "id=0 name=nil stamp=0 handleLeaf=:0 serializedLeaf=:0.0 flag=false");

        // ---- the edit-buffer shape: copy out, write, hand back ----
        row.setId(99L);
        check("a Java-side write reaches Swift when handed back",
              SerializedBridge.idAfterEdit(row), 99L);

        // The peer holds no native memory, so equality is by value. Two
        // snapshots of the same Swift value are equal; a pointer-backed peer
        // would have produced two distinct objects.
        checkTrue("value equality", SerializedBridge.makeRow().equals(SerializedBridge.makeRow()));
        check("hashCode agrees with equals",
              SerializedBridge.makeRow().hashCode(),
              SerializedBridge.makeRow().hashCode());

        // ---- the escape hatch: a type whose storage is not marshalled ----
        // Opaque's only storage is @nonjvm, so the macro generates no
        // reconstruction and the author supplies one. Round-tripping proves
        // the hand-written fromJavaObject recovered the storage behind the
        // computed facade, not just the facade.
        Swift4jFixtures.Opaque opaque = SerializedBridge.makeOpaque();
        check("opaque facade crosses", opaque.getText(), "1234567890123");
        check("hand-written fromJavaObject recovers the storage",
              SerializedBridge.opaqueRaw(opaque), "1234567890123");

        if (failures > 0) {
            System.out.println("\n" + failures + " serialized round-trip check(s) failed");
            System.exit(1);
        }
        System.out.println("\nall serialized round-trip checks passed");
    }
}
