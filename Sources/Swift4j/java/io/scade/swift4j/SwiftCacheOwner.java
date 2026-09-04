package io.scade.swift4j;

/**
 * A peer that caches marshalled children, and can be told to drop one.
 *
 * <p>A property read marshals a Swift box: a malloc, a value copy, and a reaper
 * registration. Reading the same property repeatedly — a comparator does it
 * about log n times per element — pays that every time. Caching the marshalled
 * peer bounds it to once per property per peer.
 *
 * <p>The cache is only ever a read accelerator, never a place a write can hide.
 * Any write invalidates, so a read either hits an entry that matches Swift or
 * marshals a fresh one. Without that, a write into a cached copy would be
 * reported back by the next read while Swift never saw it — a lost write
 * disguised as a successful one, which is worse than losing it outright.
 *
 * <p>Implemented by value-type peers only. A class peer's object is owned by
 * Swift and can be mutated with no bridge involvement, so there is no point at
 * which its cache could be invalidated.
 */
public interface SwiftCacheOwner {
  /** Drops the cached child in {@code slot}. Called by that child on write. */
  void _invalidateCacheSlot(int slot);
}
