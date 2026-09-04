import Swift4jFixtures.Box;
import Swift4jFixtures.Leaf;
import Swift4jFixtures.Lossy;

import io.scade.swift4j.SwiftPtr;

/**
 * Compares the read path across the two designs. Compiles unchanged on both
 * branches, so the same source measures copy semantics on `fixes` and
 * projections on `claude/projection-handles`.
 *
 * Reports nanoseconds per operation and, more usefully, how many Swift boxes
 * each shape registers with the reaper. That second number is the original
 * bug: a box per property read means a malloc, a value copy, a PhantomReference,
 * a concurrent-map insert, and a later deinit and drain.
 */
public class Bench {

  private static final int WARMUP = 50_000;
  private static final int ITERATIONS = 500_000;

  public static void main(String[] args) {
    System.loadLibrary("Swift4jFixtures");

    // The reaper's watermark can unpark a collector thread mid-run, which adds
    // noise unrelated to what is being compared.
    SwiftPtr.setPressureEnabled(false);

    System.out.println("iterations=" + ITERATIONS);
    System.out.println();

    decompose();
    System.out.println();

    singleFieldRead();
    multiFieldRead();
    nestedWrite();
    arrayElementRead();
    System.out.println();
    arrayScaling();

    System.out.println();
    System.out.println("boxes/op is the number that matters: each is a Swift malloc,");
    System.out.println("a value copy, and a reaper registration that must later be drained.");
  }

  /**
   * Splits a property read into its parts, so the microsecond can be attributed
   * rather than guessed at.
   *
   * An Int read off a root is the floor: one crossing, no allocation, no
   * conversion. A String read off the same root adds only the Swift-to-Java
   * string conversion. A nested read adds the box on top of that.
   */
  private static void decompose() {
    final Leaf leaf = new Leaf("subject-label", 1);
    final Box box = new Box(new Leaf("subject-label", 1), "tag");

    run("floor: Int off a root   leaf.getCount()", () -> leaf.getCount());
    run("String off a root       leaf.getLabel()", () -> leaf.getLabel());
    run("String off a root       box.getTag()", () -> box.getTag());
    run("box only               box.getLeaf()", () -> box.getLeaf());
    run("construct              new Leaf(...)", () -> new Leaf("x", 1));

    // The scope path, which is what the bridge recommends for edits. Every
    // entry used to resolve SwiftBorrow.with by string.
    run("scope entry            box.unsafeWithLeaf(read)", () -> {
      box.unsafeWithLeaf(l -> l.getCount());
      return null;
    });
    run("scope entry            box.unsafeWithLeaf(write)", () -> {
      box.unsafeWithLeaf(l -> l.setLabel("x"));
      return null;
    });
  }

  /** The sort path: reach one field off a nested value and discard the rest. */
  private static void singleFieldRead() {
    final Box box = new Box(new Leaf("subject-label", 1), "tag");
    run("read one field   box.getLeaf().getLabel()", () -> box.getLeaf().getLabel());
  }

  /** Where projections are expected to lose: one scope per field. */
  private static void multiFieldRead() {
    final Box box = new Box(new Leaf("subject-label", 1), "tag");
    run("read four fields off one value", () -> {
      Leaf l = box.getLeaf();
      Object sink = l.getLabel();
      sink = l.getCount();
      sink = l.getLabel();
      sink = l.getCount();
      return sink;
    });
  }

  /** Discarded on `fixes`, lands on the projection branch. Same cost shape. */
  private static void nestedWrite() {
    final Box box = new Box(new Leaf("subject-label", 1), "tag");
    run("write one field  box.getLeaf().setLabel(x)", () -> {
      box.getLeaf().setLabel("written");
      return null;
    });
  }

  /**
   * How the array getter scales. It boxes every element to hand back one, so
   * the cost of reaching index 2 is set by the length of the array, not by
   * anything the caller asked for.
   *
   * Iteration counts shrink as the arrays grow, since a single call at the top
   * end costs milliseconds.
   */
  private static void arrayScaling() {
    int[] sizes = { 4, 100, 1_000, 10_000 };
    int[] iterations = { 200_000, 20_000, 2_000, 200 };

    for (int s = 0; s < sizes.length; s++) {
      Leaf[] elements = new Leaf[sizes[s]];
      for (int i = 0; i < elements.length; i++) {
        elements[i] = new Leaf("element-" + i, i);
      }
      final Lossy lossy = new Lossy(new Leaf("a", 1), new Leaf("opt", 2), elements);

      runN(String.format("read [2] of %5d   getLeaves()[2].getLabel()", sizes[s]),
           iterations[s],
           () -> lossy.getLeaves()[2].getLabel());

      // The scope reaches the same element without boxing any of them.
      runN(String.format("scope over %5d    unsafeForEach (read all)", sizes[s]),
           iterations[s],
           () -> {
             lossy.unsafeForEachLeaves(l -> l.getCount());
             return null;
           });
    }
  }

  private static void arrayElementRead() {
    final Lossy lossy = new Lossy(new Leaf("a", 1), new Leaf("opt", 2),
                                  new Leaf[] { new Leaf("e0", 1), new Leaf("e1", 2),
                                               new Leaf("e2", 3), new Leaf("e3", 4) });
    run("read one element lossy.getLeaves()[2].getLabel()",
        () -> lossy.getLeaves()[2].getLabel());
  }

  private interface Op {
    Object run();
  }

  private static void run(String name, Op op) {
    runN(name, ITERATIONS, op);
  }

  private static void runN(String name, int iterations, Op op) {
    for (int i = 0; i < Math.min(WARMUP, iterations); i++) {
      op.run();
    }

    // Settle what warmup registered, so the delta below is this run's alone.
    for (int i = 0; i < 3; i++) {
      System.gc();
      try {
        Thread.sleep(50);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }

    long boxesBefore = SwiftPtr.totalRegistered();
    long start = System.nanoTime();
    for (int i = 0; i < iterations; i++) {
      op.run();
    }
    long elapsed = System.nanoTime() - start;
    long boxes = SwiftPtr.totalRegistered() - boxesBefore;

    System.out.printf("  %-44s %7.1f ns/op   %6.2f boxes/op%n",
                      name,
                      (double) elapsed / iterations,
                      (double) boxes / iterations);
  }
}
