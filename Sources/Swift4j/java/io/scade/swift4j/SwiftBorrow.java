package io.scade.swift4j;

/**
 * Receives a borrowed view of Swift storage for the duration of one call.
 *
 * <p>The value handed to {@link #with} points into memory owned by something
 * else. It is valid only until {@code with} returns. Storing it, or using it
 * from another thread that outlives the call, reads freed or reused memory —
 * a native crash, not an exception. Every API that hands one out is named
 * {@code unsafe*} for that reason.
 *
 * <p>Writes through it are writes into the owner. That is the point: it is how
 * a nested value is edited without copying it out and back.
 */
@FunctionalInterface
public interface SwiftBorrow<T> {
  void with(T value);
}
