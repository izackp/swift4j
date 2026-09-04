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

    singleFieldRead();
    multiFieldRead();
    nestedWrite();
    arrayElementRead();

    System.out.println();
    System.out.println("boxes/op is the number that matters: each is a Swift malloc,");
    System.out.println("a value copy, and a reaper registration that must later be drained.");
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
    for (int i = 0; i < WARMUP; i++) {
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
    for (int i = 0; i < ITERATIONS; i++) {
      op.run();
    }
    long elapsed = System.nanoTime() - start;
    long boxes = SwiftPtr.totalRegistered() - boxesBefore;

    System.out.printf("  %-44s %7.1f ns/op   %6.2f boxes/op%n",
                      name,
                      (double) elapsed / ITERATIONS,
                      (double) boxes / ITERATIONS);
  }
}
