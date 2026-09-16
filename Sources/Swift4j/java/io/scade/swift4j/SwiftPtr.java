package io.scade.swift4j;

import java.lang.ref.PhantomReference;
import java.lang.ref.ReferenceQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.LockSupport;

/**
 * A handle to Swift-owned storage. Immutable: the address it holds is valid for
 * the handle's whole lifetime, and the storage is released by the reaper once
 * this object becomes unreachable.
 *
 * There is deliberately no explicit release. Freeing on demand would let Java
 * invalidate an address that a borrow may still be pointing into, and the
 * resulting failure is a native use-after-free rather than an exception. GC
 * reachability is the only lifetime rule.
 *
 * Because a handle is a few dozen Java bytes standing in for a Swift object
 * that may be kilobytes, the collector has no Java-heap reason to run while
 * native memory fills up. Two things address that: the native footprint is
 * reported to the Android runtime so ordinary GC pressure accounts for it (see
 * {@link #nativeAccountingAvailable}), and a watermark on the live-handle count
 * requests a collection as a backstop. The watermark has a hard ceiling, so the
 * standing population cannot drift upward without bound.
 */
public final class SwiftPtr {

  @FunctionalInterface
  public interface DeinitFn {
    void deinit(long ptr);
  }

  private final long ptr;

  /** Non-owning handle: nothing here frees the address. */
  public SwiftPtr(long ptr) {
    this.ptr = ptr;
  }

  public SwiftPtr(long ptr, DeinitFn deinit) {
    this(ptr, deinit, Reaper.DEFAULT_NATIVE_BYTES);
  }

  /**
   * @param nativeBytes native footprint of the Swift object, reported to the
   *                    runtime so ordinary GC pressure accounts for it. This is
   *                    not bookkeeping that merely has to balance: the runtime
   *                    cannot see memory held behind a handle, so it is the only
   *                    reason a collection happens before native memory runs
   *                    out. Under-reporting buys a crash, not an inaccurate
   *                    report. Pass zero or less where the size is genuinely
   *                    unknown, which falls back to a nominal default.
   */
  public SwiftPtr(long ptr, DeinitFn deinit, long nativeBytes) {
    this.ptr = ptr;
    if (deinit != null) {
      Reaper.register(this, ptr, deinit,
                      nativeBytes > 0L ? nativeBytes : Reaper.DEFAULT_NATIVE_BYTES);
    }
  }

  public long get() {
    return ptr;
  }

  /** SwiftPtr instances that still own an unreleased Swift object. */
  public static int liveCount() {
    return Reaper.LIVE.get();
  }

  public static long totalRegistered() {
    return Reaper.REGISTERED.get();
  }

  public static long totalFreed() {
    return Reaper.FREED.get();
  }

  /** Live-handle count at which the next collection is requested. */
  public static int currentWatermark() {
    return Reaper.WATERMARK.get();
  }

  /**
   * Measurement only: holds the reapers so a backlog of enqueued references can
   * accumulate before a drain is timed.
   *
   * Not a lifetime control, and not useful in an application -- while paused,
   * nothing is reclaimed. It exists because a drain timed from an unpaused
   * reaper is dominated by how fast the collector enqueues rather than by how
   * fast the reaper frees, which moves the result by 2x between runs and hides
   * any change to the drain itself. See ReaperBench.
   */
  public static void pauseReapers(boolean paused) {
    Reaper.PAUSED = paused;
  }

  /** Estimated native bytes held by the handles counted by {@link #liveCount}. */
  public static long nativeBytesOutstanding() {
    return Reaper.NATIVE_BYTES.get();
  }

  /**
   * True when this runtime can tell the VM about the native memory a handle
   * pins, so an ordinary GC is triggered by that memory rather than only by the
   * few dozen Java bytes of the wrapper. Android only; false on a plain JVM,
   * where the watermark below is the whole mechanism.
   */
  public static boolean nativeAccountingAvailable() {
    return NativeHeap.AVAILABLE;
  }

  /** Turns off the reporting described by {@link #nativeAccountingAvailable}. */
  public static void setNativeAccountingEnabled(boolean enabled) {
    Reaper.NATIVE_ACCOUNTING_ENABLED = enabled;
  }

  /**
   * Sets the per-handle footprint assumed by the two-argument constructor,
   * which is the one generated code calls. Callers that know the real size
   * should pass it to {@link #SwiftPtr(long, DeinitFn, long)} instead.
   */
  public static void setDefaultNativeSize(long bytes) {
    Reaper.DEFAULT_NATIVE_BYTES = Math.max(0L, bytes);
  }

  /**
   * Hard ceiling on the live-handle count at which a collection is requested.
   * The adaptive watermark may never be raised above this, so the standing
   * population cannot drift upward without bound.
   */
  public static void setLiveCeiling(int handles) {
    Reaper.LIVE_CEILING = Math.max(Reaper.MIN_STEP, handles);
  }

  /**
   * Enables the watermark-driven collection that keeps native memory bounded.
   * On by default; disable to fall back to purely GC-driven reclamation.
   */
  public static void setPressureEnabled(boolean enabled) {
    Reaper.PRESSURE_ENABLED = enabled;
  }

  /**
   * Bounds how far the live-handle count may run ahead of the reaper before an
   * allocating thread waits for it to catch up. Off by default: blocking an
   * allocating thread trades a leak for a stall, so it must be opted into.
   * The thread registered via {@link #setMainThread} never waits.
   */
  public static void setBackpressure(boolean enabled, int limit, long maxWaitMs) {
    Reaper.BACKPRESSURE_ENABLED = enabled;
    Reaper.BACKPRESSURE_LIMIT = Math.max(1, limit);
    Reaper.BACKPRESSURE_WAIT_MS = Math.max(0L, maxWaitMs);
  }

  /** Marks a thread as never eligible for backpressure waits. */
  public static void setMainThread(Thread thread) {
    Reaper.MAIN_THREAD = thread;
  }

  /**
   * Reports native memory to the Android runtime, which is the only party that
   * can act on it: ART triggers a GC from registered native bytes the same way
   * it does for {@code DirectByteBuffer}.
   *
   * {@code dalvik.system.VMRuntime.registerNativeAllocation/registerNativeFree}
   * are hidden but carry {@code @UnsupportedAppUsage} with no {@code
   * maxTargetSdk}, so they sit on the "unsupported" list and stay callable by
   * reflection at any target SDK (checked against the AOSP hidden-API lists
   * through Android 15: they appear in no max-target-* or blocked list). The
   * count-based alternative the platform prefers for malloc'd memory,
   * {@code notifyNativeAllocation}, carries no such annotation and is therefore
   * blocked to apps, so it is not an option here.
   *
   * Everything is resolved reflectively and once. On a non-Android JVM nothing
   * resolves, {@link #AVAILABLE} is false, and the class costs nothing.
   */
  private static final class NativeHeap {

    private static final Object RUNTIME;
    private static final java.lang.reflect.Method ALLOC;
    private static final java.lang.reflect.Method FREE;
    private static final boolean LONG_ARG;
    static final boolean AVAILABLE;

    static {
      Object runtime = null;
      java.lang.reflect.Method alloc = null;
      java.lang.reflect.Method free = null;
      boolean longArg = true;
      try {
        Class<?> vm = Class.forName("dalvik.system.VMRuntime");
        runtime = vm.getMethod("getRuntime").invoke(null);
        try {
          alloc = vm.getMethod("registerNativeAllocation", long.class);
          free = vm.getMethod("registerNativeFree", long.class);
        } catch (Throwable noLongOverload) {
          alloc = vm.getMethod("registerNativeAllocation", int.class);
          free = vm.getMethod("registerNativeFree", int.class);
          longArg = false;
        }
        alloc.setAccessible(true);
        free.setAccessible(true);
      } catch (Throwable notAndroid) {
        runtime = null;
        alloc = null;
        free = null;
      }
      RUNTIME = runtime;
      ALLOC = alloc;
      FREE = free;
      LONG_ARG = longArg;
      AVAILABLE = runtime != null && alloc != null && free != null;
    }

    private static Object arg(long bytes) {
      if (LONG_ARG) return Long.valueOf(bytes);
      return Integer.valueOf((int) Math.min(bytes, Integer.MAX_VALUE));
    }

    static void allocated(long bytes) {
      if (!AVAILABLE || bytes <= 0L) return;
      try {
        ALLOC.invoke(RUNTIME, arg(bytes));
      } catch (Throwable ignored) {
      }
    }

    static void freed(long bytes) {
      if (!AVAILABLE || bytes <= 0L) return;
      try {
        FREE.invoke(RUNTIME, arg(bytes));
      } catch (Throwable ignored) {
      }
    }
  }

  private static final class Reaper {

    private static final int MIN_STEP = 512;
    private static final int MAX_STEP = 8192;
    private static final long MIN_GC_INTERVAL_NS = 2_000_000_000L;

    /**
     * Reclamation is a JNI deinit per phantom reference, so draining a large
     * population takes hundreds of milliseconds even spread across the reaper
     * threads. The old 250 ms budget could not observe a real drain, which made
     * every pass look ineffective. Kept generous: the budget only bounds how
     * long a pass waits, and the pass exits as soon as the drain goes idle.
     */
    private static final long DRAIN_BUDGET_MS = 5_000L;
    private static final long DRAIN_POLL_MS = 10L;
    /** How long to wait for ART to enqueue the first phantom reference. */
    private static final long DRAIN_GRACE_MS = 500L;
    /** Consecutive polls with no reclamation that mean the reaper is idle. */
    private static final int DRAIN_IDLE_POLLS = 10;

    private static final int DEFAULT_LIVE_CEILING = 32768;
    private static final long DEFAULT_HANDLE_BYTES = 512L;

    private static volatile long DEFAULT_NATIVE_BYTES = DEFAULT_HANDLE_BYTES;
    private static volatile int LIVE_CEILING = DEFAULT_LIVE_CEILING;
    private static volatile boolean NATIVE_ACCOUNTING_ENABLED = true;

    private static volatile boolean PRESSURE_ENABLED = true;
    private static volatile boolean BACKPRESSURE_ENABLED = false;
    private static volatile int BACKPRESSURE_LIMIT = DEFAULT_LIVE_CEILING;
    private static volatile long BACKPRESSURE_WAIT_MS = 50L;
    private static volatile Thread MAIN_THREAD = null;

    private static final ReferenceQueue<Object> QUEUE = new ReferenceQueue<>();

    private static final ConcurrentHashMap<PhantomReference<Object>, Cleanup>
      REFS = new ConcurrentHashMap<>();

    private static final AtomicInteger LIVE = new AtomicInteger();
    private static final AtomicLong REGISTERED = new AtomicLong();
    private static final AtomicLong FREED = new AtomicLong();
    private static final AtomicLong NATIVE_BYTES = new AtomicLong();
    private static final AtomicInteger WATERMARK = new AtomicInteger(MIN_STEP);
    private static final AtomicInteger STEP = new AtomicInteger(MIN_STEP);

    private static volatile Thread PRESSURE_THREAD;

    private static final class Cleanup {
      final long ptr;
      final DeinitFn deinit;
      final long bytes;

      Cleanup(long ptr, DeinitFn deinit, long bytes) {
        this.ptr = ptr;
        this.deinit = deinit;
        this.bytes = bytes;
      }

      void free() {
        try {
          deinit.deinit(ptr);
        } catch (Throwable ignored) {
        } finally {
          LIVE.decrementAndGet();
          FREED.incrementAndGet();
          if (bytes > 0L) {
            NATIVE_BYTES.addAndGet(-bytes);
            NativeHeap.freed(bytes);
          }
        }
      }
    }

    /**
     * Reclamation is dominated by the Swift side: for a value with refcounted
     * fields, releasing them and freeing the storage is 70-80% of the measured
     * per-object cost, against under 60 ns for the queue and map bookkeeping
     * combined. That work parallelises, because deinit of distinct instances is
     * independent -- a {@link Cleanup} holds a pointer and a per-class static
     * native, and the generated peer's property cache is per-instance Java
     * state that reclamation never touches.
     *
     * Half the cores, capped at four: a reaper runs above normal priority, so
     * taking every core would trade a native-memory stall for a UI stall. Eight
     * threads measured slower than four on an eight-core host anyway.
     */
    private static final int REAPER_THREADS =
      Math.max(1, Math.min(4, Runtime.getRuntime().availableProcessors() / 2));

    /**
     * Dequeue in batches: one blocking {@code remove()} followed by
     * non-blocking {@code poll()}s.
     *
     * This buys nothing with a single reaper -- measured flat across batch
     * sizes. It matters because there are several: every {@code remove()} and
     * {@code poll()} takes the queue's monitor, so reapers contend on it once
     * per handle, and amortising that over a batch was worth a further 21% at
     * four threads.
     */
    private static final int DRAIN_BATCH = 64;

    /** @see SwiftPtr#pauseReapers */
    static volatile boolean PAUSED = false;

    private static void reap() {
      @SuppressWarnings("unchecked")
      PhantomReference<Object>[] batch =
        (PhantomReference<Object>[]) new PhantomReference<?>[DRAIN_BATCH];

      while (true) {
        int n = 0;
        try {
          while (PAUSED) LockSupport.parkNanos(200_000L);
          @SuppressWarnings("unchecked")
          PhantomReference<Object> first =
            (PhantomReference<Object>) QUEUE.remove();
          batch[n++] = first;

          while (n < batch.length) {
            java.lang.ref.Reference<?> more = QUEUE.poll();
            if (more == null) break;
            @SuppressWarnings("unchecked")
            PhantomReference<Object> ref = (PhantomReference<Object>) more;
            batch[n++] = ref;
          }
        } catch (InterruptedException ignored) {
        } catch (Throwable ignored) {
        }

        // Outside the dequeue's catch: a failure while collecting the batch
        // must still free what was already taken, or those handles leak with
        // nothing left holding their reference.
        for (int i = 0; i < n; i++) {
          PhantomReference<Object> ref = batch[i];
          batch[i] = null;
          try {
            Cleanup cleanup = REFS.remove(ref);
            if (cleanup != null) {
              cleanup.free();
            }
            ref.clear();
          } catch (Throwable ignored) {
          }
        }
      }
    }

    static {
      for (int i = 0; i < REAPER_THREADS; i++) {
        Thread reaper = new Thread(Reaper::reap, "SwiftPtr-Reaper-" + i);
        reaper.setDaemon(true);
        reaper.setPriority(Thread.NORM_PRIORITY + 1);
        reaper.start();
      }

      Thread pressure = new Thread(() -> {
        long lastGcNs = System.nanoTime() - MIN_GC_INTERVAL_NS;
        while (true) {
          LockSupport.park();
          if (!PRESSURE_ENABLED) continue;

          long now = System.nanoTime();
          if (now - lastGcNs < MIN_GC_INTERVAL_NS) continue;
          lastGcNs = now;

          try {
            collect();
          } catch (Throwable ignored) {
          }
        }
      }, "SwiftPtr-Pressure");
      pressure.setDaemon(true);
      pressure.start();
      PRESSURE_THREAD = pressure;
    }

    /**
     * Runs on the dedicated pressure thread only. Never the caller (that is the
     * UI stall we are trying to avoid) and never a reaper thread, which would
     * deadlock a collection against the queue it is draining. Nothing in
     * {@link #reap} reaches this, which is what keeps that true however many
     * reapers there are.
     */
    private static void collect() {
      int before = LIVE.get();
      long freedBefore = FREED.get();
      System.gc();
      drain();
      int after = LIVE.get();

      // Measured on FREED, not on the live count: new registrations arriving
      // during the pass inflate the live count and would otherwise be read as
      // a failure to reclaim.
      long reclaimed = FREED.get() - freedBefore;

      int step = STEP.get();
      if (reclaimed >= before / 2) {
        // Reclamation is keeping up, so the same trigger can be reached less
        // often without the population growing.
        step = Math.min(MAX_STEP, step * 2);
      } else if (reclaimed < before / 4) {
        // Reclamation is NOT keeping up. The old code backed off here, which
        // is right for a poll and wrong for a memory bound: it deferred the
        // next collection exactly when the population was growing. Tighten.
        step = Math.max(MIN_STEP, step / 2);
      }
      STEP.set(step);

      int ceiling = LIVE_CEILING;
      long watermark = (long) after + (long) step;
      WATERMARK.set((int) Math.min(watermark, (long) ceiling));
    }

    /**
     * Waits for the reaper to go idle rather than for the first handle to drop.
     * The old loop exited as soon as the live count fell by one, so a pass that
     * had barely started was scored as having reclaimed almost nothing.
     */
    private static void drain() {
      long start = FREED.get();
      long lastFreed = start;
      long waited = 0L;
      int idle = 0;

      while (waited < DRAIN_BUDGET_MS) {
        try {
          Thread.sleep(DRAIN_POLL_MS);
        } catch (InterruptedException ignored) {
          return;
        }
        waited += DRAIN_POLL_MS;

        long freedNow = FREED.get();
        if (freedNow > lastFreed) {
          lastFreed = freedNow;
          idle = 0;
          continue;
        }
        if (lastFreed == start && waited < DRAIN_GRACE_MS) {
          // Nothing reclaimed yet; ART has not finished enqueueing.
          idle = 0;
          continue;
        }
        if (++idle >= DRAIN_IDLE_POLLS) {
          return;
        }
      }
    }

    private static void applyBackpressure() {
      if (Thread.currentThread() == MAIN_THREAD) return;
      long deadline = System.nanoTime() + BACKPRESSURE_WAIT_MS * 1_000_000L;
      while (LIVE.get() >= BACKPRESSURE_LIMIT && System.nanoTime() < deadline) {
        try {
          Thread.sleep(5L);
        } catch (InterruptedException ignored) {
          return;
        }
      }
    }

    static void register(Object owner, long ptr, DeinitFn deinit, long nativeBytes) {
      long bytes = (NATIVE_ACCOUNTING_ENABLED && NativeHeap.AVAILABLE) ? nativeBytes : 0L;

      PhantomReference<Object> ref = new PhantomReference<>(owner, QUEUE);
      REFS.put(ref, new Cleanup(ptr, deinit, bytes));

      REGISTERED.incrementAndGet();
      int live = LIVE.incrementAndGet();

      if (bytes > 0L) {
        NATIVE_BYTES.addAndGet(bytes);
        NativeHeap.allocated(bytes);
      }

      if (PRESSURE_ENABLED && live >= WATERMARK.get()) {
        Thread t = PRESSURE_THREAD;
        if (t != null) LockSupport.unpark(t);

        if (BACKPRESSURE_ENABLED && live >= BACKPRESSURE_LIMIT) {
          applyBackpressure();
        }
      }
    }
  }
}
