package io.scade.swift4j;

import java.lang.ref.PhantomReference;
import java.lang.ref.ReferenceQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.LockSupport;

public final class SwiftPtr implements AutoCloseable {

  @FunctionalInterface
  public interface DeinitFn {
    void deinit(long ptr);
  }

  private volatile long ptr;
  private final PhantomReference<Object> ref;

  public SwiftPtr(long ptr) {
    this.ptr = ptr;
    this.ref = null;
  }

  public SwiftPtr(long ptr, DeinitFn deinit) {
    this.ptr = ptr;
    this.ref = deinit == null ? null : Reaper.register(this, ptr, deinit);
  }

  public long get() {
    long p = ptr;
    if (p == 0L && ref != null) {
      throw new IllegalStateException("SwiftPtr has already been closed");
    }
    return p;
  }

  public boolean isClosed() {
    return ref != null && ptr == 0L;
  }

  /**
   * Releases the Swift object now rather than waiting for the garbage collector.
   * Idempotent, and safe to race against the reaper. A SwiftPtr constructed
   * without a DeinitFn does not own its pointer, so this is a no-op for it.
   */
  @Override
  public void close() {
    if (ref == null) return;
    ptr = 0L;
    Reaper.unregister(ref);
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

  private static final class Reaper {

    private static final int MIN_STEP = 512;
    private static final int MAX_STEP = 65536;
    private static final long MIN_GC_INTERVAL_NS = 2_000_000_000L;
    private static final long DRAIN_BUDGET_MS = 250L;

    private static volatile boolean PRESSURE_ENABLED = true;
    private static volatile boolean BACKPRESSURE_ENABLED = false;
    private static volatile int BACKPRESSURE_LIMIT = MAX_STEP;
    private static volatile long BACKPRESSURE_WAIT_MS = 50L;
    private static volatile Thread MAIN_THREAD = null;

    private static final ReferenceQueue<Object> QUEUE = new ReferenceQueue<>();

    private static final ConcurrentHashMap<PhantomReference<Object>, Cleanup>
      REFS = new ConcurrentHashMap<>();

    private static final AtomicInteger LIVE = new AtomicInteger();
    private static final AtomicLong REGISTERED = new AtomicLong();
    private static final AtomicLong FREED = new AtomicLong();
    private static final AtomicInteger WATERMARK = new AtomicInteger(MIN_STEP);
    private static final AtomicInteger STEP = new AtomicInteger(MIN_STEP);

    private static volatile Thread PRESSURE_THREAD;

    private static final class Cleanup {
      final long ptr;
      final DeinitFn deinit;

      Cleanup(long ptr, DeinitFn deinit) {
        this.ptr = ptr;
        this.deinit = deinit;
      }

      void free() {
        try {
          deinit.deinit(ptr);
        } catch (Throwable ignored) {
        } finally {
          LIVE.decrementAndGet();
          FREED.incrementAndGet();
        }
      }
    }

    static {
      Thread reaper = new Thread(() -> {
        while (true) {
          try {
            @SuppressWarnings("unchecked")
            PhantomReference<Object> ref =
              (PhantomReference<Object>) QUEUE.remove();

            Cleanup cleanup = REFS.remove(ref);
            if (cleanup != null) {
              cleanup.free();
            }

            ref.clear();
          } catch (InterruptedException ignored) {
          } catch (Throwable ignored) {
          }
        }
      }, "SwiftPtr-Reaper");
      reaper.setDaemon(true);
      reaper.setPriority(Thread.NORM_PRIORITY + 1);
      reaper.start();

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
     * UI stall we are trying to avoid) and never the reaper thread, which would
     * deadlock a collection against the queue it is draining.
     */
    private static void collect() {
      int before = LIVE.get();
      System.gc();
      drain(before);
      int after = LIVE.get();

      int freed = before - after;
      int step = STEP.get();
      if (freed < before / 4) {
        step = Math.min(MAX_STEP, step * 2);
      } else if (freed > before / 2) {
        step = Math.max(MIN_STEP, step / 2);
      }
      STEP.set(step);
      WATERMARK.set(after + step);
    }

    private static void drain(int before) {
      long waited = 0L;
      while (waited < DRAIN_BUDGET_MS && LIVE.get() >= before) {
        try {
          Thread.sleep(10L);
        } catch (InterruptedException ignored) {
          return;
        }
        waited += 10L;
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

    static PhantomReference<Object> register(Object owner, long ptr, DeinitFn deinit) {
      PhantomReference<Object> ref = new PhantomReference<>(owner, QUEUE);
      REFS.put(ref, new Cleanup(ptr, deinit));

      REGISTERED.incrementAndGet();
      int live = LIVE.incrementAndGet();

      if (PRESSURE_ENABLED && live >= WATERMARK.get()) {
        Thread t = PRESSURE_THREAD;
        if (t != null) LockSupport.unpark(t);

        if (BACKPRESSURE_ENABLED && live >= BACKPRESSURE_LIMIT) {
          applyBackpressure();
        }
      }
      return ref;
    }

    static void unregister(PhantomReference<Object> ref) {
      Cleanup cleanup = REFS.remove(ref);
      ref.clear();
      if (cleanup != null) {
        cleanup.free();
      }
    }
  }
}
