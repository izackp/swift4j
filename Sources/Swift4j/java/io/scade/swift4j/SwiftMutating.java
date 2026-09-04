package io.scade.swift4j;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks a method that writes to its receiver.
 *
 * <p>Applied to every generated setter, and to methods the Swift declaration
 * marks {@code mutating}. Non-mutating methods are deliberately left unmarked:
 * calling one on a temporary is harmless, and marking them would flag it.
 *
 * <p>Paired with {@link SwiftCopyingGetter} by an analyzer. Neither annotation
 * means anything on its own — the defect is the combination, a write to a
 * receiver that nothing can observe afterwards.
 */
@Retention(RetentionPolicy.CLASS)
@Target(ElementType.METHOD)
public @interface SwiftMutating {
}
