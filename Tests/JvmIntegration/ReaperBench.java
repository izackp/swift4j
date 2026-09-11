import Swift4jFixtures.Leaf;
import Swift4jFixtures.Lossy;

import io.scade.swift4j.SwiftPtr;

import java.util.concurrent.locks.LockSupport;

/**
 * Measures stage 3 of reclamation: how fast the reapers turn enqueued phantom
 * references into freed Swift objects. Stages 1 and 2 (triggering a collection,
 * the GC tracing and enqueueing) are deliberately excluded -- the reapers are
 * held via SwiftPtr.pauseReapers while the whole population is enqueued, and
 * only then released and timed.
 *
 * That gate is what makes the number mean anything. Timed without it, a reaper
 * spends most of the drain blocked waiting on the single thread that moves
 * discovered references onto the queue, the result swings by 2x between
 * processes, and a change to the drain itself is invisible.
 *
 * Three populations, because the per-object cost is split between the JNI
 * crossing and whatever Swift has to release, and only a payload sweep can say
 * which dominates:
 *
 *   light   Leaf("L123", i). The label is short enough to live inline in the
 *           String, so deinit releases nothing and only frees the struct's
 *           malloc. This is the floor: JNI crossing plus one free().
 *
 *   heavy   Lossy with a 30-element Leaf array whose labels are long enough to
 *           be heap-allocated. deinit frees the array buffer and decrements 30
 *           String refcounts. The Strings are shared across the population, so
 *           the decrements do not reach zero -- this isolates the cost of the
 *           release traffic from the cost of the frees it eventually causes.
 *
 *   unique  Same shape, but every Lossy owns 30 Strings of its own, so each
 *           deinit performs 31 real frees. Run at a smaller population because
 *           building it costs 30 peer constructions per object.
 */
public final class ReaperBench {

  static {
    System.loadLibrary("Swift4jFixtures");
  }

  public static void main(String[] args) throws Exception {
    String mode = args.length > 0 ? args[0] : "light";
    int n = args.length > 1 ? Integer.parseInt(args[1]) : defaultCount(mode);

    // The pressure thread calls System.gc() on its own schedule; a collection
    // landing mid-measurement would mix stage 1 back into the number.
    SwiftPtr.setPressureEnabled(false);

    int reapers = 0;
    for (Thread t : Thread.getAllStackTraces().keySet()) {
      if (t.getName().startsWith("SwiftPtr-Reaper")) reapers++;
    }
    System.out.printf("mode=%s population=%d reapers=%d cores=%d accounting=%s%n",
                      mode, n, reapers,
                      Runtime.getRuntime().availableProcessors(),
                      SwiftPtr.nativeAccountingAvailable());

    // The reaper loop runs once per handle, so a cold measurement is mostly
    // interpreted bytecode. Drain a tenth of the population first to get it
    // compiled.
    Object[] warm = build(mode, Math.max(1, n / 10));
    warm = null;
    settle();

    // Rounds inside one JVM, reported individually. Across processes the
    // numbers move by more than the effect being measured -- machine state
    // dominates -- so a config is judged by the median of its rounds and
    // configs are compared only when interleaved.
    int rounds = Integer.getInteger("bench.rounds", 5);
    double[] perObj = new double[rounds];
    for (int r = 0; r < rounds; r++) {
      perObj[r] = round(mode, n);
    }
    java.util.Arrays.sort(perObj);
    System.out.printf("  MEDIAN           %8.0f ns/object   (%.0f objects/s)%n",
                      perObj[rounds / 2], 1e9 / perObj[rounds / 2]);
  }

  private static double round(String mode, int n) {
    Object[] pop = build(mode, n);

    // Setup allocates peers of its own (the Leaf elements, intermediate
    // Strings). Flush that garbage before the baseline so the measured drain
    // contains the population and nothing else.
    settle();

    long base = SwiftPtr.totalFreed();
    int liveBefore = SwiftPtr.liveCount();

    pop = null;

    // Hold the reapers while the collector enqueues the whole population, so
    // the timed window is the drain and not the enqueue rate. Without this the
    // reaper spends most of its time blocked, the numbers swing by 2x between
    // processes, and no change to the drain is visible at all.
    SwiftPtr.pauseReapers(true);
    long g0 = System.nanoTime();
    System.gc();
    sleep(2000);
    long enqueueMs = (System.nanoTime() - g0) / 1_000_000L;

    long t0 = System.nanoTime();
    SwiftPtr.pauseReapers(false);

    long firstNs = -1L;
    long lastNs = 0L;
    long seen = base;
    long deadline = t0 + 180_000_000_000L;

    while (System.nanoTime() < deadline) {
      long freed = SwiftPtr.totalFreed();
      if (freed > seen) {
        long now = System.nanoTime();
        if (firstNs < 0L) firstNs = now;
        lastNs = now;
        seen = freed;
      }
      if (seen - base >= n) break;
      LockSupport.parkNanos(50_000L);
    }

    long reclaimed = seen - base;
    long drainNs = (firstNs < 0L) ? 0L : (lastNs - firstNs);

    double ns = reclaimed == 0 ? 0.0 : (double) drainNs / reclaimed;

    System.out.printf("  round: reclaimed %d/%d  gc+enqueue %5d ms  drain %6.1f ms"
                      + "  %6.0f ns/obj  (live %d -> %d)%n",
                      reclaimed, n, enqueueMs, drainNs / 1e6, ns,
                      liveBefore, SwiftPtr.liveCount());

    return ns;
  }

  private static int defaultCount(String mode) {
    return mode.equals("unique") ? 20_000 : 200_000;
  }

  private static Object[] build(String mode, int n) {
    Object[] pop = new Object[n];

    if (mode.equals("light")) {
      for (int i = 0; i < n; i++) {
        pop[i] = new Leaf("L" + i, i);
      }
      return pop;
    }

    Leaf spare = new Leaf(longLabel("spare"), 0);

    if (mode.equals("heavy")) {
      Leaf[] shared = new Leaf[30];
      for (int i = 0; i < shared.length; i++) {
        shared[i] = new Leaf(longLabel("shared-" + i), i);
      }
      for (int i = 0; i < n; i++) {
        pop[i] = new Lossy(shared[0], spare, shared);
      }
      return pop;
    }

    if (mode.equals("unique")) {
      for (int i = 0; i < n; i++) {
        Leaf[] own = new Leaf[30];
        for (int j = 0; j < own.length; j++) {
          own[j] = new Leaf(longLabel(i + "-" + j), j);
        }
        pop[i] = new Lossy(own[0], spare, own);
      }
      return pop;
    }

    throw new IllegalArgumentException("unknown mode: " + mode);
  }

  /** Past Swift's 15-byte small-string limit, so the storage is heap-allocated. */
  private static String longLabel(String seed) {
    return "label-" + seed + "-0123456789abcdefghijklmnopqrstuvwxyz";
  }

  private static void settle() {
    for (int i = 0; i < 6; i++) {
      System.gc();
      long before = SwiftPtr.totalFreed();
      sleep(150);
      while (SwiftPtr.totalFreed() > before) {
        before = SwiftPtr.totalFreed();
        sleep(150);
      }
    }
  }

  private static void sleep(long ms) {
    try {
      Thread.sleep(ms);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }
}
