import Swift4jFixtures.Box;
import Swift4jFixtures.Leaf;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The two memory-safety hazards named in task.md, exercised rather than argued.
 *
 * Both can take down the JVM rather than fail an assertion, which is exactly
 * the point: a Java data race gives a wrong value, a race on Swift storage
 * gives SIGSEGV in swift_release. So this runs as its own process and the
 * harness reports how it died.
 *
 * A clean run does NOT prove safety. These are races and use-after-free; they
 * are probabilistic. Absence of a crash in one run means the window was not
 * hit, not that the window is closed.
 *
 * Pass a scenario name as argv[0]: "race" or "escape".
 */
public class DangerTest {

  public static void main(String[] args) throws Exception {
    System.loadLibrary("Swift4jFixtures");

    String scenario = args.length > 0 ? args[0] : "race-root";
    switch (scenario) {
      case "race-root": rootAccessorRace(); break;
      case "race": crossThreadMutation(); break;
      case "escape": escapedBorrow(); break;
      default:
        System.out.println("unknown scenario: " + scenario);
        System.exit(2);
    }
  }

  /**
   * The race that ordinary code hits, and the one D8 fixes.
   *
   * No borrowing, no nested struct, no unsafeWith: one shared peer, a plain
   * setter on one thread and a plain getter on four others. `setTag` is
   * release-then-store on a refcounted field and `getTag` is load-then-retain,
   * so without a guard the release lands between the reader's two steps and
   * the reader retains freed memory.
   *
   * The strings must exceed Swift's small-string capacity (15 UTF-8 bytes) or
   * there is no hazard to test: a short String is stored inline in the struct,
   * with no refcounted buffer to release. An earlier version of this scenario
   * wrote "w0", "w1", ... and survived nine million unguarded iterations for
   * exactly that reason.
   *
   * Unlike the scenarios below, this one is expected to SURVIVE. It is the
   * before/after evidence for the peer lock: with the `synchronized (_ptr)`
   * removed from the generated accessors this dies in swift_release within a
   * second or two.
   */
  private static void rootAccessorRace() throws Exception {
    final String PAD = "-------------------------------";  // pushes past 15 bytes
    final Box box = new Box(new Leaf("start", 0), "tag" + PAD);
    final AtomicBoolean stop = new AtomicBoolean(false);
    final AtomicReference<Throwable> error = new AtomicReference<>();

    Thread writer = new Thread(() -> {
      long i = 0;
      while (!stop.get()) {
        try {
          box.setTag("w" + (i++) + PAD);
        } catch (Throwable t) {
          error.compareAndSet(null, t);
          return;
        }
      }
      System.out.println("  writer completed " + i + " iterations");
    }, "writer");

    Thread[] readers = new Thread[4];
    for (int r = 0; r < readers.length; r++) {
      readers[r] = new Thread(() -> {
        while (!stop.get()) {
          try {
            String s = box.getTag();
            if (s == null || !s.endsWith(PAD)) {
              error.compareAndSet(null, new IllegalStateException("read a torn tag: " + s));
              return;
            }
          } catch (Throwable t) {
            error.compareAndSet(null, t);
            return;
          }
        }
      }, "reader-" + r);
    }

    writer.start();
    for (Thread t : readers) t.start();

    Thread.sleep(3000);
    stop.set(true);

    writer.join(5000);
    for (Thread t : readers) t.join(5000);

    Throwable t = error.get();
    if (t != null) {
      System.out.println("  BROKEN: guarded accessors still raced: " + t);
      System.exit(1);
    }
    System.out.println("  3s of guarded concurrent read/write, no fault");
  }

  /**
   * Danger 1: cross-thread mutation while another thread reads.
   *
   * Assigning a refcounted field is release(old) then retain(new), which is not
   * atomic. A reader can load the old String pointer, the writer can drop it to
   * zero and dealloc, and the reader then retains freed memory.
   *
   * Swift's defence is exclusivity enforcement; the bridge hands out a raw
   * pointer and bypasses it.
   *
   * The peer lock does NOT cover this, deliberately. An unsafeWith scope holds
   * an interior pointer into the owner for its whole duration, so excluding a
   * concurrent writer would mean holding the lock across the callback — and
   * arbitrary Java runs there, free to take JVM monitors and deadlock against
   * a thread waiting on this one. The `unsafe` prefix is the contract: callers
   * serialise their own scopes. So this is still expected to die.
   */
  private static void crossThreadMutation() throws Exception {
    final Box box = new Box(new Leaf("start", 0), "tag");
    final AtomicBoolean stop = new AtomicBoolean(false);
    final AtomicReference<Throwable> error = new AtomicReference<>();

    Thread writer = new Thread(() -> {
      int i = 0;
      while (!stop.get()) {
        try {
          box.unsafeWithLeaf(l -> l.setLabel("w" + System.nanoTime()));
          i++;
        } catch (Throwable t) {
          error.compareAndSet(null, t);
          return;
        }
      }
      System.out.println("  writer completed " + i + " iterations");
    }, "writer");

    Thread[] readers = new Thread[4];
    for (int r = 0; r < readers.length; r++) {
      readers[r] = new Thread(() -> {
        while (!stop.get()) {
          try {
            String s = box.getLeaf().getLabel();
            if (s == null) {
              error.compareAndSet(null, new IllegalStateException("read a null label"));
              return;
            }
            // Touch the contents so a freed buffer is actually dereferenced.
            if (s.length() < 0) System.out.println(s);
          } catch (Throwable t) {
            error.compareAndSet(null, t);
            return;
          }
        }
      }, "reader-" + r);
    }

    writer.start();
    for (Thread t : readers) t.start();

    Thread.sleep(3000);
    stop.set(true);

    writer.join(5000);
    for (Thread t : readers) t.join(5000);

    Throwable t = error.get();
    if (t != null) {
      System.out.println("  DANGER observed: " + t);
      System.exit(1);
    }
    System.out.println("  survived 3s of concurrent read/write");
    System.out.println("  (not proof of safety: the race window was simply not hit)");
  }

  /**
   * Danger 2: a borrow escaping its scope.
   *
   * unsafeWith hands the callback a view into the owner's storage, valid only
   * for the call. Storing it is what the `unsafe` prefix warns about; nothing
   * prevents it, because Java has no lifetime annotations.
   *
   * The owner is kept alive here first, to separate "escaped" from "escaped and
   * dangling" — the second step drops the owner and collects it.
   */
  private static void escapedBorrow() throws Exception {
    // Storing the view at all now takes a deliberate declaration. The lambda
    // parameter is Leaf.Borrowed, not Leaf, so the accidental version —
    //
    //     AtomicReference<Leaf> escaped = ...;
    //     box.unsafeWithLeaf(l -> escaped.set(l));
    //
    // does not compile. That is the first line of defence, and it is why this
    // test has to opt in to the danger explicitly.
    final AtomicReference<Leaf.Borrowed> escaped = new AtomicReference<>();

    Box box = new Box(new Leaf("owned", 7), "tag");

    String insideScope = readInside(box, escaped);
    if (!"owned".equals(insideScope)) {
      System.out.println("  DANGER: view read \"" + insideScope + "\" inside its own scope");
      System.exit(1);
    }
    System.out.println("  view readable inside its scope: \"" + insideScope + "\"");

    // Second line of defence: the view is invalidated on the way out, so this
    // throws instead of dereferencing a pointer whose owner may already be
    // gone. Before this existed the same call died with SIGSEGV in
    // swift_retain once the owner was collected.
    try {
      escaped.get().getLabel();
      System.out.println("  DANGER: escaped view still readable after its scope ended");
      System.exit(1);
    } catch (IllegalStateException expected) {
      System.out.println("  escaped view threw on use after scope: " + expected.getMessage());
    }

    // And still throws once the owner is gone, rather than reading freed memory.
    box = null;
    for (int i = 0; i < 5; i++) {
      System.gc();
      Thread.sleep(100);
    }

    try {
      escaped.get().getLabel();
      System.out.println("  DANGER: escaped view readable after the owner was collected");
      System.exit(1);
    } catch (IllegalStateException expected) {
      System.out.println("  escaped view still throws after the owner was collected");
    }

    System.out.println("  escape hazard contained");
  }

  private static String readInside(Box box, AtomicReference<Leaf.Borrowed> escaped) {
    final String[] seen = new String[1];
    box.unsafeWithLeaf(l -> {
      escaped.set(l);
      seen[0] = l.getLabel();
    });
    return seen[0];
  }
}
