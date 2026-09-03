import Swift4jFixtures.Box;
import Swift4jFixtures.Leaf;
import Swift4jFixtures.Branch;
import Swift4jFixtures.Holder;
import Swift4jFixtures.Lossy;

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

    // Known defects. These assert what the bridge does today, not what it
    // should do. Green here includes real bugs.
    pinnedPlainGetterLosesWrites();
    pinnedMutatingMethodOnNestedValueIsDiscarded();
    pinnedOptionalPropertyHasNoScope();
    pinnedArrayElementWritesAreLost();

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

  // ---------------------------------------------------------------------
  // Pinned defects.
  //
  // Each of these asserts a silent write loss that the bridge still has. They
  // pass because the bug is present. If one starts failing, the behaviour
  // changed — check whether that was intended, then update or delete the pin.
  // ---------------------------------------------------------------------

  /**
   * The plain getter boxes a copy, so a write through it lands in a malloc
   * nothing reads again. This is the default path and the reason unsafeWith
   * exists; it is not fixed, only avoidable.
   */
  private static void pinnedPlainGetterLosesWrites() {
    Box box = new Box(new Leaf("orig", 1), "tag");

    box.getLeaf().setLabel("lost");

    check("PINNED: plain getter write is discarded",
          box.getLeaf().getLabel().equals("orig"));
  }

  /**
   * `mutating` is invisible to the bridge — it generates the same plain void as
   * a read-only method. On a property box the mutation dies with the box, which
   * is worse than a setter because nothing in the Java signature looks like a
   * write.
   */
  private static void pinnedMutatingMethodOnNestedValueIsDiscarded() {
    Box box = new Box(new Leaf("m", 5), "tag");

    box.getLeaf().bump();
    check("PINNED: mutating method on a nested value is discarded",
          box.getLeaf().getCount() == 5);

    // On an owned root it does persist, which is the inconsistency.
    Leaf root = new Leaf("m", 5);
    root.bump();
    check("mutating method on an owned root persists", root.getCount() == 6);
  }

  /**
   * Optional<T> is not laid out as T, so there is no address to hand out and
   * the rule excludes it. Writes through the getter are therefore lost with no
   * scoped alternative to reach for.
   */
  private static void pinnedOptionalPropertyHasNoScope() {
    boolean scope = false;
    for (Method m : Lossy.class.getMethods()) {
      if (m.getName().equals("unsafeWithMaybe")) scope = true;
    }
    check("PINNED: optional property has no scoped borrow", !scope);

    Lossy lossy = new Lossy(new Leaf("a", 1), new Leaf("opt", 2), new Leaf[] { new Leaf("e", 3) });
    lossy.getMaybe().setLabel("lost");
    check("PINNED: optional property write is discarded",
          lossy.getMaybe().getLabel().equals("opt"));
  }

  /**
   * Array marshalling boxes one owned copy per element, so an element write
   * never reaches the array it came from. G3 in task.md; unresolved.
   */
  private static void pinnedArrayElementWritesAreLost() {
    Lossy lossy = new Lossy(new Leaf("a", 1), null, new Leaf[] { new Leaf("elem", 3) });

    lossy.getLeaves()[0].setLabel("lost");

    check("PINNED: array element write is discarded",
          lossy.getLeaves()[0].getLabel().equals("elem"));
  }

  private static void check(String what, boolean ok) {
    System.out.println((ok ? "  ok   " : "  FAIL ") + what);
    if (!ok) failures++;
  }
}
