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

import java.lang.reflect.Method;
import java.util.HashMap;

/**
 * The only place the bridge actually runs.
 *
 * Everything else in this repo checks generated text or type-checks an
 * expansion. Neither catches a RegisterNatives batch that fails at class-init,
 * a value that aliases when it should copy, or a write that lands nowhere.
 *
 * Checks labelled PINNED assert what the bridge does *today*, including known
 * defects. They pass because the bug is present; if one fails, the behaviour
 * changed and the pin needs re-deciding rather than "fixing".
 */
public class BridgeIntegrationTest {

  private static int failures = 0;

  public static void main(String[] args) throws Exception {
    System.loadLibrary("Swift4jFixtures");

    section("registration");
    registerNativesSucceeds();

    section("getter semantics by property type");
    structPropertyReturnsDistinctInstances();
    structPropertyWriteIsDiscarded();
    classPropertyWriteReachesTheOwner();
    classPropertyReturnsTheSamePeer();
    optionalPropertyNonNilWriteIsDiscarded();
    optionalPropertyNilReturnsNull();
    arrayPropertyElementWriteIsDiscarded();
    arrayPropertyReturnsDistinctArrays();
    dictionaryPropertyRoundTrips();
    datePropertyRoundTripsAndWriteIsDiscarded();
    scalarPropertiesOnARootRoundTrip();

    section("copy()");
    copyOfStructIsIndependent();
    copyDetachesANestedValue();
    copySharesANestedReference();
    classHasNoCopy();

    section("unsafeWith");
    scopedWriteLandsInTheOwner();
    scopedReadReturnsTheCurrentValue();
    scopedAccessNests();
    scopeOnACopyAffectsOnlyTheCopy();
    scopedWriteRunsObservers();
    conversionBridgedPropertyHasNoPublicScope();

    section("mutating methods");
    mutatingMethodOnARootPersists();
    mutatingMethodOnANestedValueIsDiscarded();
    mutatingMethodInsideAScopeLands();

    section("identity, equality, hashing");
    hashableStructComparesByValue();
    twoGetterCallsAreEqualButNotIdentical();
    mutatingAKeyAfterInsertionOrphansIt();

    section("enums");
    simpleEnumPropertyRoundTrips();
    payloadEnumPeerIsKotlinSoItIsNotCoveredHere();

    section("lifetime");
    aFetchedCopyOutlivesItsOwner();
    handlesReturnToBaselineAfterCollection();

    if (failures > 0) {
      System.out.println("\n" + failures + " check(s) failed");
      System.exit(1);
    }
    System.out.println("\nall checks passed");
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

  private static void structPropertyReturnsDistinctInstances() {
    Box box = new Box(new Leaf("a", 1), "tag");
    check("struct getter returns a fresh instance each call",
          box.getLeaf() != box.getLeaf());
  }

  private static void structPropertyWriteIsDiscarded() {
    Box box = new Box(new Leaf("orig", 1), "tag");
    box.getLeaf().setLabel("lost");
    check("PINNED: struct property write is discarded",
          box.getLeaf().getLabel().equals("orig"));
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

  private static void optionalPropertyNonNilWriteIsDiscarded() {
    Lossy lossy = new Lossy(new Leaf("a", 1), new Leaf("opt", 2), new Leaf[] { new Leaf("e", 3) });
    lossy.getMaybe().setLabel("lost");
    check("PINNED: optional property write is discarded",
          lossy.getMaybe().getLabel().equals("opt"));

    check("PINNED: optional property has no scoped borrow",
          !hasMethod(Lossy.class, "unsafeWithMaybe"));
  }

  private static void optionalPropertyNilReturnsNull() {
    Lossy lossy = new Lossy(new Leaf("a", 1), null, new Leaf[0]);
    check("nil optional reads back as null", lossy.getMaybe() == null);
  }

  private static void arrayPropertyElementWriteIsDiscarded() {
    Lossy lossy = new Lossy(new Leaf("a", 1), null, new Leaf[] { new Leaf("elem", 3) });
    lossy.getLeaves()[0].setLabel("lost");
    check("PINNED: array element write is discarded",
          lossy.getLeaves()[0].getLabel().equals("elem"));
  }

  private static void arrayPropertyReturnsDistinctArrays() {
    Lossy lossy = new Lossy(new Leaf("a", 1), null, new Leaf[] { new Leaf("e", 3) });
    check("array getter marshals a fresh array each call",
          lossy.getLeaves() != lossy.getLeaves());
  }

  private static void dictionaryPropertyRoundTrips() {
    Branch branch = branchFixture();
    check("dictionary property reads back its entry",
          branch.getTable().get("k").getLabel().equals("v"));
  }

  private static void datePropertyRoundTripsAndWriteIsDiscarded() {
    Branch branch = branchFixture();
    java.util.Date fetched = branch.getStamp();
    check("Date property round-trips", fetched.getTime() == 1000L);

    fetched.setTime(5000L);
    check("PINNED: mutating a fetched Date does not reach the owner",
          branch.getStamp().getTime() == 1000L);
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

  /**
   * The same copy retains rather than clones a reference field, so the class
   * stays shared. Shallow by construction — worth knowing, not a defect.
   */
  private static void copySharesANestedReference() {
    Mixed original = new Mixed(new Leaf("a", 1), new Holder(1, new Leaf("h", 2)));
    Mixed duplicate = original.copy();

    duplicate.getHolder().setCount(42);

    check("copy shares the nested reference", original.getHolder().getCount() == 42);
  }

  private static void classHasNoCopy() {
    check("class has no copy()", !hasMethod(Holder.class, "copy"));
    check("class has no fromUnownedPtr", !hasDeclaredMethod(Holder.class, "fromUnownedPtr"));
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
   * The distinction between a scope and an interior pointer. A scope is an
   * inout access, so it runs the synthesized modify accessor and observers
   * fire. Writing through a raw field address would skip them.
   */
  private static void scopedWriteRunsObservers() {
    Observing o = new Observing(new Leaf("a", 1));
    check("observer has not run yet", o.getObserverRuns() == 0);

    o.unsafeWithLeaf(l -> l.setLabel("x"));

    check("scoped write ran didSet", o.getObserverRuns() == 1);
  }

  private static void conversionBridgedPropertyHasNoPublicScope() {
    check("Date property exposes no public scope",
          !hasMethod(Branch.class, "unsafeWithStamp"));
    check("Date property still declares its native",
          hasDeclaredMethod(Branch.class, "unsafeWithStampImpl"));
    check("struct property does expose a scope",
          hasMethod(Branch.class, "unsafeWithLeaf"));
    check("class-typed property exposes no scope",
          !hasMethod(Mixed.class, "unsafeWithHolder"));
  }

  // ---- mutating methods ----

  private static void mutatingMethodOnARootPersists() {
    Leaf root = new Leaf("m", 5);
    root.bump();
    check("mutating method on an owned root persists", root.getCount() == 6);
  }

  private static void mutatingMethodOnANestedValueIsDiscarded() {
    Box box = new Box(new Leaf("m", 5), "tag");
    box.getLeaf().bump();
    check("PINNED: mutating method on a nested value is discarded",
          box.getLeaf().getCount() == 5);
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

  private static void twoGetterCallsAreEqualButNotIdentical() {
    Box box = new Box(new Leaf("a", 1), "tag");
    check("two fetches are equal by value", box.getLeaf().equals(box.getLeaf()));
    check("two fetches are not the same object", box.getLeaf() != box.getLeaf());
  }

  /**
   * Standard Java: HashMap's contract is undefined if a key's hash changes
   * while it is in the map. Recorded because a value-typed key makes it easy to
   * hit — the fix is to insert a copy.
   */
  private static void mutatingAKeyAfterInsertionOrphansIt() {
    HashMap<Leaf, String> map = new HashMap<>();
    Leaf key = new Leaf("k", 1);
    map.put(key, "value");

    key.setLabel("mutated");

    check("PINNED: mutating a key after put orphans the entry", map.get(key) == null);

    Leaf stable = new Leaf("k2", 1);
    map.put(stable, "value2");
    check("an unmutated key is still found", "value2".equals(map.get(stable)));
  }

  // ---- enums ----

  private static void simpleEnumPropertyRoundTrips() {
    Shaped shaped = new Shaped(Color.red);
    check("simple enum reads back", shaped.getColor() == Color.red);

    shaped.setColor(Color.blue);
    check("simple enum setter on a root", shaped.getColor() == Color.blue);
  }

  /**
   * Not a check, a recorded limitation: a payload enum's peer is emitted as
   * Kotlin (a sealed class), so this javac-only harness cannot compile it and
   * the case goes untested here.
   */
  private static void payloadEnumPeerIsKotlinSoItIsNotCoveredHere() {
    note("payload enum peer is Kotlin (Shape.kt); not covered by this harness");
  }

  // ---- lifetime ----

  /** A fetched value owns its own allocation, so it does not depend on its source. */
  private static void aFetchedCopyOutlivesItsOwner() {
    Box box = new Box(new Leaf("kept", 1), "tag");
    Leaf detached = box.getLeaf();
    box = null;

    System.gc();
    try { Thread.sleep(50); } catch (InterruptedException ignored) { }

    check("a fetched value survives its owner", detached.getLabel().equals("kept"));
  }

  /**
   * Lenient by design: GC timing is not deterministic, so this asserts handles
   * do not grow without bound, not an exact count.
   */
  private static void handlesReturnToBaselineAfterCollection() {
    int before = SwiftPtr.liveCount();
    for (int i = 0; i < 2000; i++) {
      new Box(new Leaf("x", i), "t").getLeaf().getLabel();
    }
    for (int i = 0; i < 3; i++) {
      System.gc();
      try { Thread.sleep(50); } catch (InterruptedException ignored) { }
    }
    int after = SwiftPtr.liveCount();
    check("live handles do not grow without bound after 2000 boxes"
          + " (before=" + before + " after=" + after + ")",
          after < before + 2000);
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

  private static boolean hasMethod(Class<?> cls, String name) {
    for (Method m : cls.getMethods()) {
      if (m.getName().equals(name)) return true;
    }
    return false;
  }

  private static boolean hasDeclaredMethod(Class<?> cls, String name) {
    for (Method m : cls.getDeclaredMethods()) {
      if (m.getName().equals(name)) return true;
    }
    return false;
  }

  private static void section(String name) {
    System.out.println("\n" + name);
  }

  private static void note(String what) {
    System.out.println("  note " + what);
  }

  private static void check(String what, boolean ok) {
    System.out.println((ok ? "  ok   " : "  FAIL ") + what);
    if (!ok) failures++;
  }
}
