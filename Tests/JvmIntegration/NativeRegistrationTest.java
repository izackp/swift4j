import java.lang.reflect.Method;

import Swift4jFixtures.ExtensionStatic;
import Swift4jFixtures.NativeCheckBridge;

/**
 * The macro and the swift4j CLI derive a type's bridged surface independently,
 * from different views of the source: the CLI reads every file and so sees
 * extensions, while a macro is attached to one declaration and cannot. The
 * macro therefore <em>cannot</em> register an extension-declared member — it
 * does not have the information — so the CLI must not emit one.
 *
 * <p>{@code ExtensionStatic.orphanedStatic} is declared in a Swift extension.
 * It used to reach Java as a {@code native} method that nothing bound, which no
 * build could see: Swift compiles (nothing is wrong in Swift), javac compiles
 * (a native method needs no body), and only calling it fails. In CaptureAPI
 * that was eight methods across two classes, none of them called.
 *
 * <p>Checked by reflection rather than by calling it, because the point is that
 * the method is not there to call.
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

        // Touching the class is what runs class_init, and therefore the
        // registration cross-check.
        NativeCheckBridge.loadExtensionStatic();

        boolean emitted = false;
        for (Method method : ExtensionStatic.class.getDeclaredMethods()) {
            if (method.getName().startsWith("orphanedStatic")) {
                emitted = true;
            }
        }
        checkTrue("an extension-declared static is not emitted into the peer", !emitted);

        // The class-init cross-check is the backstop for anything that gets
        // past the generator rule. With the rule in place it should have
        // nothing to say — a finding here means either the rule regressed or
        // the check itself gained a false positive.
        String[] findings = NativeCheckBridge.findings();
        for (String finding : findings) {
            System.out.println("  unexpected finding: " + finding);
        }
        checkTrue("the class-init cross-check reports nothing", findings.length == 0);

        if (failures > 0) {
            System.out.println("\n" + failures + " native registration check(s) failed");
            System.exit(1);
        }
        System.out.println("\nall native registration checks passed");
    }
}
