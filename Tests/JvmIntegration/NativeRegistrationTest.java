import Swift4jFixtures.ExtensionStatic;
import Swift4jFixtures.NativeCheckBridge;

/**
 * Proves the class-init cross-check sees a macro/CLI disagreement that nothing
 * else can.
 *
 * <p>The macro and the swift4j CLI derive the native set independently, from
 * different views of the source: the CLI reads every file and so sees
 * extensions, while a peer macro sees only the declaration it is attached to.
 * Neither the Swift build nor javac can observe a disagreement, because
 * RegisterNatives binds by name and descriptor string at runtime.
 *
 * <p>{@code ExtensionStatic.orphanedStatic} is declared in a Swift extension.
 * The CLI emits a native for it; the macro registers nothing. Note what does
 * <em>not</em> happen: the RegisterNatives batch succeeds, because only the
 * entries actually passed to it are validated. The class loads clean and the
 * defect waits for a caller.
 */
public final class NativeRegistrationTest {

    private static int failures = 0;

    private static void checkTrue(String what, boolean cond) {
        if (cond) {
            System.out.println("  ok     " + what);
        } else {
            System.out.println("  FAIL   " + what);
            failures++;
        }
    }

    public static void main(String[] args) {
        System.loadLibrary("Swift4jFixtures");

        // Touching the class is what runs class_init, and therefore the check.
        NativeCheckBridge.loadExtensionStatic();

        boolean unbound = false;
        try {
            ExtensionStatic.orphanedStatic(21L);
        } catch (UnsatisfiedLinkError expected) {
            unbound = true;
        }
        checkTrue("an extension-declared static is left unbound", unbound);

        String[] findings = NativeCheckBridge.findings();

        boolean named = false;
        for (String finding : findings) {
            if (finding.contains("orphanedStaticImpl") && finding.contains("ExtensionStatic")) {
                named = true;
            }
        }
        checkTrue("the check names the unregistered native and its class", named);

        // The point of the check is that it fires at class-load, before anyone
        // calls the method. Had it needed a call to notice, it would be no
        // earlier than the UnsatisfiedLinkError it is meant to pre-empt.
        checkTrue("it reported before any call to the orphaned method",
                  findings.length > 0);

        if (failures > 0) {
            System.out.println("\n" + failures + " native registration check(s) failed");
            System.exit(1);
        }
        System.out.println("\nall native registration checks passed");
    }
}
