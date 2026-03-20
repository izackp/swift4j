package io.scade.swift4j;

import java.lang.ref.PhantomReference;
import java.lang.ref.ReferenceQueue;
import java.util.concurrent.ConcurrentHashMap;

public final class SwiftPtr {

  @FunctionalInterface
  public interface DeinitFn {
    void deinit(long ptr);
  }

  private final long ptr;

  public SwiftPtr(long ptr) {
    this.ptr = ptr;
  }

  public SwiftPtr(long ptr, DeinitFn deinit) {
    this.ptr = ptr;
    if (deinit != null) {
      Reaper.register(this, ptr, deinit);
    }
  }

  public long get() {
    return ptr;
  }


  private static final class Reaper {

    private static final ReferenceQueue<Object> QUEUE = new ReferenceQueue<>();

    private static final class Cleanup {
      final long ptr;
      final DeinitFn deinit;

      Cleanup(long ptr, DeinitFn deinit) {
        this.ptr = ptr;
        this.deinit = deinit;
      }
    }


    private static final ConcurrentHashMap<PhantomReference<Object>, Cleanup>
      REFS = new ConcurrentHashMap<>();

    static {
      Thread t = new Thread(() -> {
        while (true) {
          try {
            @SuppressWarnings("unchecked")
            PhantomReference<Object> ref =
            (PhantomReference<Object>) QUEUE.remove();

            Cleanup cleanup = REFS.remove(ref);
            if (cleanup != null) {
              try {
                cleanup.deinit.deinit(cleanup.ptr);
              } catch (Throwable ignored) { }
            }

            ref.clear();
          } catch (InterruptedException ignored) { }
        }
      }, "SwiftPtr-Reaper");

      t.setDaemon(true);
      t.start();
    }

    static void register(Object owner, long ptr, DeinitFn deinit) {
      PhantomReference<Object> ref = new PhantomReference<>(owner, QUEUE);
      REFS.put(ref, new Cleanup(ptr, deinit));
    }
  }
}
