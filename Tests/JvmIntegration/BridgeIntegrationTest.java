import Swift4jFixtures.Box;
import Swift4jFixtures.Leaf;
import Swift4jFixtures.Branch;
import Swift4jFixtures.Holder;

import java.lang.reflect.Method;

/**
 * The only place the bridge actually runs.
 *
 * Everything else in this repo checks generated text or type-checks an
 * expansion. Neither catches a RegisterNatives batch that fails at class-init,
 * a scoped borrow that hands back a copy, or a copy() that aliases — all of
 * which are silent until an app uses them.
 */
public class BridgeIntegrationTest {

  private static int failures = 0;

  public static void main(String[] args) throws Exception {
    System.loadLibrary("Swift4jFixtures");

    registerNativesSucceeds();
    propertiesRoundTrip();
    scopedBorrowWritesReachTheOwner();
    copyIsIndependent();
    conversionBridgedPropertyHasNoPublicScope();
    classesHaveNoCopy();

    if (failures > 0) {
      System.out.println(failures + " check(s) failed");
      System.exit(1);
    }
    System.out.println("all checks passed");
  }

  /**
   * Loading the class runs its static block, which calls the class_init native.
   * If any registered native lacks a Java method the whole batch fails here,
   * unbinding every native on the class.
   */
  private static void registerNativesSucceeds() {
    Leaf leaf = new Leaf("a", 1);
    check("class init bound natives", leaf.getLabel().equals("a"));
  }

  private static void propertiesRoundTrip() {
    Leaf leaf = new Leaf("start", 7);
    check("string getter", leaf.getLabel().equals("start"));
    check("int getter", leaf.getCount() == 7);

    leaf.setLabel("changed");
    leaf.setCount(9);
    check("string setter", leaf.getLabel().equals("changed"));
    check("int setter", leaf.getCount() == 9);
  }

  /**
   * The whole point of unsafeWith: the callback gets a view into the owner's
   * storage, so a write through it is a write into the owner. With the old
   * copy-per-read bridging this silently did nothing.
   */
  private static void scopedBorrowWritesReachTheOwner() {
    Box box = new Box(new Leaf("inner", 1), "tag");

    box.unsafeWithLeaf(borrowed -> borrowed.setLabel("written-through"));

    check("borrow write reached the owner",
          box.getLeaf().getLabel().equals("written-through"));

    box.unsafeWithLeaf(borrowed -> borrowed.setCount(42));
    check("second borrow write reached the owner", box.getLeaf().getCount() == 42);
  }

  /** copy() must detach, matching `var x = y` on the Swift side. */
  private static void copyIsIndependent() {
    Box original = new Box(new Leaf("orig", 1), "tag");
    Box duplicate = original.copy();

    duplicate.unsafeWithLeaf(borrowed -> borrowed.setLabel("mutated"));

    check("copy saw its own write", duplicate.getLeaf().getLabel().equals("mutated"));
    check("original was not aliased", original.getLeaf().getLabel().equals("orig"));
  }

  /**
   * Date bridges by conversion, so there is no address to borrow. The macro
   * still registers the native (it cannot resolve type names), and the CLI must
   * declare it or class-init fails — but no public wrapper may exist, or
   * callers would get a copy while the name promises a view.
   */
  private static void conversionBridgedPropertyHasNoPublicScope() throws Exception {
    boolean publicScope = false;
    for (Method m : Branch.class.getMethods()) {
      if (m.getName().equals("unsafeWithStamp")) publicScope = true;
    }
    check("Date property exposes no public scope", !publicScope);

    boolean nativeDeclared = false;
    for (Method m : Branch.class.getDeclaredMethods()) {
      if (m.getName().equals("unsafeWithStampImpl")) nativeDeclared = true;
    }
    check("Date property still declares its native", nativeDeclared);

    boolean structScope = false;
    for (Method m : Branch.class.getMethods()) {
      if (m.getName().equals("unsafeWithLeaf")) structScope = true;
    }
    check("struct property does expose a scope", structScope);
  }

  /** A class peer refers to one Swift object; copying it would mean something else. */
  private static void classesHaveNoCopy() {
    boolean hasCopy = false;
    for (Method m : Holder.class.getMethods()) {
      if (m.getName().equals("copy")) hasCopy = true;
    }
    check("class has no copy()", !hasCopy);
  }

  private static void check(String what, boolean ok) {
    System.out.println((ok ? "  ok   " : "  FAIL ") + what);
    if (!ok) failures++;
  }
}
