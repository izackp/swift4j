package io.scade.swift4j;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks a getter whose result is a detached copy of Swift-owned storage.
 *
 * <p>Mutating the result is only meaningful if the result is kept. This is
 * fine — the copy is named, and the write is visible through it, exactly as
 * {@code var l = box.leaf} behaves in Swift:
 *
 * <pre>{@code
 * Leaf l = box.getLeaf();
 * l.setLabel("x");        // l holds "x"; box is untouched, as in Swift
 * }</pre>
 *
 * <p>This is not, because the copy is unreachable the moment the expression
 * ends, so the write provably goes nowhere:
 *
 * <pre>{@code
 * box.getLeaf().setLabel("x");   // discarded
 * }</pre>
 *
 * <p>An analyzer pairs this with {@link SwiftMutating} to flag exactly that
 * shape: a mutating call whose receiver is an unbound call to a method marked
 * here. Bind the copy if a copy was intended, or open a scope
 * ({@code unsafeWith…}) if the owner was.
 */
@Retention(RetentionPolicy.CLASS)
@Target(ElementType.METHOD)
public @interface SwiftCopyingGetter {
}
