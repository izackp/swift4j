import Swift4jFixtures.Box;
import Swift4jFixtures.Branch;
import Swift4jFixtures.Color;
import Swift4jFixtures.Holder;
import Swift4jFixtures.Leaf;
import Swift4jFixtures.Lossy;
import Swift4jFixtures.Mixed;
import Swift4jFixtures.Observing;
import Swift4jFixtures.Shaped;

import io.scade.swift4j.SwiftPtr;

import java.util.HashMap;

/**
 * Behaviour of the bridge on a real JVM.
 *
 * Two kinds of check:
 *
 *   check(...)  asserts something that must hold. A failure is a regression.
 *   mustWork(...) asserts something that *should* hold and currently does not.
 *                 It reports BROKEN and fails the run, because a defect that
 *                 reports success is worse than no test at all.
 *
 * The run therefore exits non-zero while the known defects exist. That is the
 * point: they are bugs, not features, and the suite says so every time.
 *
 * Shape assertions (which methods exist on a peer) live in the Swift unit
 * tests, which read the generated source directly. Duplicating them here as
 * reflection lookups added checks that could not fail.
 */
public class BridgeIntegrationTest {

  private static int failures = 0;
  private static int broken = 0;

  public static void main(String[] args) throws Exception {
    System.loadLibrary("Swift4jFixtures");

    section("registration");
    registerNativesSucceeds();

    section("getter semantics by property type");
    structPropertyWriteShouldReachTheOwner();
    classPropertyWriteReachesTheOwner();
    classPropertyReturnsTheSamePeer();
    optionalPropertyWriteShouldReachTheOwner();
    optionalPropertyNilReturnsNull();
    arrayElementWriteShouldReachTheArray();
    dictionaryPropertyRoundTrips();
    datePropertyRoundTrips();
    scalarPropertiesOnARootRoundTrip();

    section("copy()");
    copyOfStructIsIndependent();
    copyDetachesANestedValue();
    copySharesANestedReference();

    section("unsafeWith");
    scopedWriteLandsInTheOwner();
    scopedReadReturnsTheCurrentValue();
    scopedAccessNests();
    scopeOnACopyAffectsOnlyTheCopy();
    scopedWriteRunsObservers();

    section("mutating methods");
    mutatingMethodOnARootPersists();
    mutatingMethodOnANestedValueShouldPersist();
    mutatingMethodInsideAScopeLands();

    section("identity, equality, hashing");
    hashableStructComparesByValue();
    twoGetterCallsAreEqualByValue();
    mutatingAKeyAfterInsertionShouldNotOrphanIt();

    section("enums");
    simpleEnumPropertyRoundTrips();

    section("memory");
    handlesReturnToBaselineAfterCollection();

    System.out.println();
    if (broken > 0) {
      System.out.println(broken + " known defect(s) still broken");
    }
    if (failures > 0) {
      System.out.println(failures + " regression(s)");
    }
    if (broken > 0 || failures > 0) {
      System.exit(1);
    }
    System.out.println("all checks passed");
  }

  // ---- registration ----

  /**
   * Loading a class runs its static block, which calls class_init. If any
   * registered native has no Java method the whole batch fails here, unbinding
   * every native on the class.
   */
  private static void registerNativesSucceeds() {
    check("class init bound natives", new Leaf("a", 1).getLabel().equals("a"));
  }

  // ---- getter semantics ----

  /** The getter boxes a copy, so the write goes to a malloc nothing reads again. */
  private static void structPropertyWriteShouldReachTheOwner() {
    Box box = new Box(new Leaf("orig", 1), "tag");
    box.getLeaf().setLabel("written");
    mustWork("struct property write reaches the owner",
             box.getLeaf().getLabel().equals("written"));
  }

  /** A class peer refers to the Swift object itself, so mutation is shared. */
  private static void classPropertyWriteReachesTheOwner() {
    Mixed mixed = new Mixed(new Leaf("a", 1), new Holder(1, new Leaf("h", 2)));
    mixed.getHolder().setCount(9);
    check("class property write reaches the owner",
          mixed.getHolder().getCount() == 9);
  }

  /** JObjectRef caches one Java peer per Swift object. */
  private static void classPropertyReturnsTheSamePeer() {
    Mixed mixed = new Mixed(new Leaf("a", 1), new Holder(1, new Leaf("h", 2)));
    check("class getter returns the same peer each call",
          mixed.getHolder() == mixed.getHolder());
  }

  /** Optional<T> is not laid out as T, so it has no scope and no view. */
  private static void optionalPropertyWriteShouldReachTheOwner() {
    Lossy lossy = new Lossy(new Leaf("a", 1), new Leaf("opt", 2), new Leaf[] { new Leaf("e", 3) });
    lossy.getMaybe().setLabel("written");
    mustWork("optional property write reaches the owner",
             lossy.getMaybe().getLabel().equals("written"));
  }

  private static void optionalPropertyNilReturnsNull() {
    Lossy lossy = new Lossy(new Leaf("a", 1), null, new Leaf[0]);
    check("nil optional reads back as null", lossy.getMaybe() == null);
  }

  /** Array marshalling boxes one owned copy per element. */
  private static void arrayElementWriteShouldReachTheArray() {
    Lossy lossy = new Lossy(new Leaf("a", 1), null, new Leaf[] { new Leaf("elem", 3) });
    lossy.getLeaves()[0].setLabel("written");
    mustWork("array element write reaches the array",
             lossy.getLeaves()[0].getLabel().equals("written"));
  }

  private static void dictionaryPropertyRoundTrips() {
    Branch branch = branchFixture();
    check("dictionary property reads back its entry",
          branch.getTable().get("k").getLabel().equals("v"));
  }

  private static void datePropertyRoundTrips() {
    Branch branch = branchFixture();
    check("Date property round-trips", branch.getStamp().getTime() == 1000L);
  }

  private static void scalarPropertiesOnARootRoundTrip() {
    Leaf leaf = new Leaf("start", 7);
    check("String getter", leaf.getLabel().equals("start"));
    check("Int getter", leaf.getCount() == 7);

    leaf.setLabel("changed");
    leaf.setCount(9);
    check("String setter on a root", leaf.getLabel().equals("changed"));
    check("Int setter on a root", leaf.getCount() == 9);
  }

  // ---- copy() ----

  private static void copyOfStructIsIndependent() {
    Box original = new Box(new Leaf("orig", 1), "tag");
    Box duplicate = original.copy();

    duplicate.setTag("changed");
    check("copy saw its own write", duplicate.getTag().equals("changed"));
    check("original was not aliased by copy", original.getTag().equals("tag"));
  }

  /** A struct copy is a full value copy, so an inline nested value detaches. */
  private static void copyDetachesANestedValue() {
    Mixed original = new Mixed(new Leaf("orig", 1), new Holder(1, new Leaf("h", 2)));
    Mixed duplicate = original.copy();

    duplicate.unsafeWithLeaf(l -> l.setLabel("changed"));

    check("copy's nested value changed", duplicate.getLeaf().getLabel().equals("changed"));
    check("original's nested value is detached", original.getLeaf().getLabel().equals("orig"));
  }

  /** The same copy retains rather than clones a reference field. */
  private static void copySharesANestedReference() {
    Mixed original = new Mixed(new Leaf("a", 1), new Holder(1, new Leaf("h", 2)));
    Mixed duplicate = original.copy();

    duplicate.getHolder().setCount(42);

    check("copy shares the nested reference", original.getHolder().getCount() == 42);
  }

  // ---- unsafeWith ----

  private static void scopedWriteLandsInTheOwner() {
    Box box = new Box(new Leaf("inner", 1), "tag");
    box.unsafeWithLeaf(l -> l.setLabel("written-through"));
    check("scoped write lands in the owner",
          box.getLeaf().getLabel().equals("written-through"));
  }

  private static void scopedReadReturnsTheCurrentValue() {
    Box box = new Box(new Leaf("readable", 3), "tag");
    String[] seen = new String[1];
    box.unsafeWithLeaf(l -> seen[0] = l.getLabel());
    check("scoped read sees the owner's value", "readable".equals(seen[0]));
  }

  /** A class with a struct property also gets a scope. */
  private static void scopedAccessNests() {
    Mixed mixed = new Mixed(new Leaf("a", 1), new Holder(1, new Leaf("deep", 2)));
    mixed.getHolder().unsafeWithLeaf(l -> l.setLabel("nested-write"));
    check("scope on a class property's struct field lands",
          mixed.getHolder().getLeaf().getLabel().equals("nested-write"));
  }

  private static void scopeOnACopyAffectsOnlyTheCopy() {
    Box original = new Box(new Leaf("orig", 1), "tag");
    Box duplicate = original.copy();

    duplicate.unsafeWithLeaf(l -> l.setLabel("mutated"));

    check("scope on a copy changed the copy", duplicate.getLeaf().getLabel().equals("mutated"));
    check("scope on a copy left the original alone", original.getLeaf().getLabel().equals("orig"));
  }

  /**
   * A scope is an inout access, so it runs the synthesized modify accessor and
   * observers fire. Writing through a raw field address would skip them.
   */
  private static void scopedWriteRunsObservers() {
    Observing o = new Observing(new Leaf("a", 1));
    check("observer has not run yet", o.getObserverRuns() == 0);
    o.unsafeWithLeaf(l -> l.setLabel("x"));
    check("scoped write ran didSet", o.getObserverRuns() == 1);
  }

  // ---- mutating methods ----

  private static void mutatingMethodOnARootPersists() {
    Leaf root = new Leaf("m", 5);
    root.bump();
    check("mutating method on an owned root persists", root.getCount() == 6);
  }

  /**
   * `mutating` is invisible to the bridge, so this is the same plain void as a
   * read-only method and the mutation dies with the boxed copy.
   */
  private static void mutatingMethodOnANestedValueShouldPersist() {
    Box box = new Box(new Leaf("m", 5), "tag");
    box.getLeaf().bump();
    mustWork("mutating method on a nested value persists", box.getLeaf().getCount() == 6);
  }

  private static void mutatingMethodInsideAScopeLands() {
    Box box = new Box(new Leaf("m", 5), "tag");
    box.unsafeWithLeaf(l -> l.bump());
    check("mutating method inside a scope lands", box.getLeaf().getCount() == 6);
  }

  // ---- identity, equality, hashing ----

  private static void hashableStructComparesByValue() {
    check("equal values are equal", new Leaf("a", 1).equals(new Leaf("a", 1)));
    check("different values are unequal", !new Leaf("a", 1).equals(new Leaf("b", 1)));
  }

  private static void twoGetterCallsAreEqualByValue() {
    Box box = new Box(new Leaf("a", 1), "tag");
    check("two fetches are equal by value", box.getLeaf().equals(box.getLeaf()));
  }

  /**
   * A mutable value-typed key silently orphans its entry. Java's HashMap
   * contract says the behaviour is undefined, so this is arguably correct — but
   * the peer offers no immutable key type and no warning, so a caller has
   * nothing to reach for.
   */
  private static void mutatingAKeyAfterInsertionShouldNotOrphanIt() {
    HashMap<Leaf, String> map = new HashMap<>();
    Leaf key = new Leaf("k", 1);
    map.put(key, "value");

    key.setLabel("mutated");

    mustWork("a key stays findable after being mutated", "value".equals(map.get(key)));
  }

  // ---- enums ----

  private static void simpleEnumPropertyRoundTrips() {
    Shaped shaped = new Shaped(Color.red, new Swift4jFixtures.Shape.circle(1));
    check("simple enum reads back", shaped.getColor() == Color.red);

    shaped.setColor(Color.blue);
    check("simple enum setter on a root", shaped.getColor() == Color.blue);
  }

  // ---- memory ----

  /**
   * Strict: 2000 boxes must be reclaimed, not merely "not unbounded". A lenient
   * bound here passed while leaking, which made the check decoration.
   */
  private static void handlesReturnToBaselineAfterCollection() {
    int before = SwiftPtr.liveCount();
    for (int i = 0; i < 2000; i++) {
      new Box(new Leaf("x", i), "t").getLeaf().getLabel();
    }
    for (int i = 0; i < 5; i++) {
      System.gc();
      try { Thread.sleep(100); } catch (InterruptedException ignored) { }
    }
    int after = SwiftPtr.liveCount();
    check("live handles return to baseline after 2000 boxes"
          + " (before=" + before + " after=" + after + ")",
          after <= before + 50);
  }

  // ---- helpers ----

  private static Branch branchFixture() {
    HashMap<String, Leaf> table = new HashMap<>();
    table.put("k", new Leaf("v", 1));
    try {
      return new Branch(new Leaf("l", 1),
                        new java.util.Date(1000L),
                        new java.net.URL("https://example.com"),
                        "name",
                        new byte[] { 1, 2 },
                        3L,
                        true,
                        null,
                        new Leaf[] { new Leaf("e", 1) },
                        table,
                        new Leaf("imm", 1),
                        new Leaf("obs", 1));
    } catch (java.net.MalformedURLException e) {
      throw new RuntimeException(e);
    }
  }

  private static void section(String name) {
    System.out.println("\n" + name);
  }

  private static void check(String what, boolean ok) {
    System.out.println((ok ? "  ok     " : "  FAIL   ") + what);
    if (!ok) failures++;
  }

  /** Asserts correct behaviour that the bridge does not yet deliver. */
  private static void mustWork(String what, boolean ok) {
    System.out.println((ok ? "  FIXED  " : "  BROKEN ") + what);
    if (!ok) broken++;
  }
}
