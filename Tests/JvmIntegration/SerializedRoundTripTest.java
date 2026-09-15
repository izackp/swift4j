import Swift4jFixtures.SerializedBridge;
import Swift4jFixtures.SerializedRow;
import Swift4jFixtures.SerializedLeaf;
import Swift4jFixtures.SerializedOptionalPrimitives;
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

        // ---- instance methods on a peer with no pointer ----
        // The native takes no address. JNI hands the peer over as the receiver
        // and the thunk rebuilds the Swift value from the marshalled fields, so
        // this is the only proof that the reconstruction recurses correctly
        // through a nested serialized member *and* a nested handle member on
        // the dispatch path, not just through an explicit static.
        SerializedRow fresh = SerializedBridge.makeRow();
        check("instance method dispatches without a pointer",
              fresh.summarize(), "42:hello:leaf:inner");
        check("instance method takes parameters",
              fresh.scaled(4.0), 10.0);

        // The receiver is rebuilt per call, so a Java-side write is visible to
        // the very next dispatch — the edit-buffer shape, reached through an
        // instance method instead of being passed to a static.
        fresh.setName("edited");
        check("a Java-side write reaches the rebuilt receiver",
              fresh.summarize(), "42:edited:leaf:inner");

        // ---- mutating methods: copy-in, mutate, copy-out ----
        // The receiver is a temporary rebuilt from the peer's fields, so the
        // only thing that makes the write visible here is the copy-back
        // through the peer's setters. Without it these read unchanged.
        SerializedLeaf leaf = row.getSerializedLeaf();
        check("mutable peer starts as marshalled", leaf.getLabel(), "inner");
        leaf.rename("renamed");
        check("a mutating method's write reaches the peer", leaf.getLabel(), "renamed");

        // Mutates and returns: the copy-back runs after the return value is
        // computed, so both the result and the field must be right.
        check("a mutating method still returns its value", leaf.scale(4.0), 10.0);
        check("and the mutation landed too", leaf.getWeight(), 10.0);

        // Copy-out writes the whole value, so an untouched property must come
        // back unchanged rather than reset to a default.
        check("an untouched property survives the copy-back", leaf.getLabel(), "renamed");

        // Diverges from Swift, and pinned here because it is the surprising
        // half: a nested serialized value is a Java *reference* held in the
        // container's field, so the getter hands back the same object every
        // time and the mutation shows through the container. Reading
        // `row.serializedLeaf` in Swift would have copied it.
        //
        // Nothing reaches the Swift side either way — `row` is itself a
        // detached snapshot — so this changes what a Java caller observes, not
        // what the database holds.
        checkTrue("a nested value is shared by reference, not copied",
                  row.getSerializedLeaf() == leaf);
        check("so the container observes the mutation",
              row.getSerializedLeaf().getLabel(), "renamed");

        // ---- what else does the copy-back touch? ----
        // The copy-back writes the whole value, so it has to leave everything
        // the method did not change exactly as it was — including the identity
        // of the Java objects a caller may already be holding.
        SerializedRow probe = SerializedBridge.makeRow();
        Leaf beforeHandle = probe.getHandleLeaf();
        SerializedLeaf beforeNested = probe.getSerializedLeaf();
        long beforeStamp = probe.getStamp().getTime();
        boolean beforeFlag = probe.getFlag();

        probe.demote();

        check("the mutated property lands", probe.getId(), -1L);
        check("a derived field is recomputed, not left stale",
              probe.getFlag(), false);
        check("and it really did change", beforeFlag, true);
        checkTrue("an untouched nested handle keeps its identity",
                  probe.getHandleLeaf() == beforeHandle);
        checkTrue("an untouched nested value keeps its identity",
                  probe.getSerializedLeaf() == beforeNested);
        check("Date is unchanged by the copy-back", probe.getStamp().getTime(), beforeStamp);

        // The point of updating in place rather than replacing: a reference
        // taken *before* the mutation must observe the new value, not sit on a
        // detached object still reporting the old one.
        probe.relabelChildren("relabelled");
        check("a reference held across the call sees the new value",
              beforeNested.getLabel(), "relabelled");
        check("same for a handle-backed member",
              beforeHandle.getLabel(), "relabelled");
        checkTrue("and was updated, not replaced",
                  probe.getSerializedLeaf() == beforeNested);

        // ---- the escape hatch: a type whose storage is not marshalled ----
        // Opaque's only storage is @nonjvm, so the macro generates no
        // reconstruction and the author supplies one. Round-tripping proves
        // the hand-written fromJavaObject recovered the storage behind the
        // computed facade, not just the facade.
        Swift4jFixtures.Opaque opaque = SerializedBridge.makeOpaque();
        check("opaque facade crosses", opaque.getText(), "1234567890123");
        check("storage that crosses as another type reads as a field",
              opaque.getRaw(), "1234567890123");

        // The write goes through Swift, so the conversion is the validator. A
        // value this side cannot represent is a caller's mistake and surfaces
        // here, at the line that made it — not later, at some crossing far
        // from the cause.
        Swift4jFixtures.Opaque writable = SerializedBridge.makeOpaque();
        writable.setRaw("999");
        check("a valid write lands", writable.getRaw(), "999");

        boolean threw = false;
        try {
            writable.setRaw("not-a-number");
        } catch (Throwable t) {
            threw = true;
        }
        checkTrue("a value Swift cannot represent is refused", threw);
        check("and the field is untouched by the refused write",
              writable.getRaw(), "999");
        check("the generated reconstruction recovers the storage",
              SerializedBridge.opaqueRaw(opaque), "1234567890123");

        // Optional primitives are boxed on the way out: Optional has no
        // toJavaParameter() witness when Wrapped is a primitive, and the
        // constructor takes Integer/Long/Double/Boolean, not int/long/etc.
        // Only running this proves the boxed descriptor matches.
        SerializedOptionalPrimitives set = SerializedBridge.makeOptionalPrimitives(true);
        check("boxed Int32? crosses", set.getCount(), Integer.valueOf(-7));
        check("boxed Int64? crosses", set.getSize(), Long.valueOf(9_000_000_000L));
        check("boxed Double? crosses", set.getRatio(), Double.valueOf(0.25));
        check("boxed Bool? crosses", set.getFlag(), Boolean.TRUE);
        check("optional String alongside", set.getLabel(), "set");

        SerializedOptionalPrimitives none = SerializedBridge.makeOptionalPrimitives(false);
        check("nil Int32? arrives null", none.getCount(), null);
        check("nil Int64? arrives null", none.getSize(), null);
        check("nil Double? arrives null", none.getRatio(), null);
        check("nil Bool? arrives null", none.getFlag(), null);
        check("nil String? arrives null", none.getLabel(), null);

        // Java -> Swift, so the reconstruction unboxes what it was handed.
        check("boxed optionals reconstruct",
              SerializedBridge.sumOptionalPrimitives(set), 8_999_999_993L);
        check("null optionals reconstruct as nil",
              SerializedBridge.sumOptionalPrimitives(none), 0L);

        if (failures > 0) {
            System.out.println("\n" + failures + " serialized round-trip check(s) failed");
            System.exit(1);
        }
        System.out.println("\nall serialized round-trip checks passed");
    }
}
