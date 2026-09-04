package io.scade.swift4j;

/**
 * Opens a scope over some Swift storage and runs {@code body} against a live
 * view of it.
 *
 * <p>This is what backs a projection: a peer that owns no storage of its own and
 * instead re-enters its owner for every operation. Each call is a fresh scope,
 * so nothing here holds a pointer between operations.
 */
@FunctionalInterface
public interface SwiftScope {
  void open(SwiftBorrow body);
}
