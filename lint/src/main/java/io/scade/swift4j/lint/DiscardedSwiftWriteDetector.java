package io.scade.swift4j.lint;

import com.android.tools.lint.detector.api.Category;
import com.android.tools.lint.detector.api.Detector;
import com.android.tools.lint.detector.api.Implementation;
import com.android.tools.lint.detector.api.Issue;
import com.android.tools.lint.detector.api.JavaContext;
import com.android.tools.lint.detector.api.Scope;
import com.android.tools.lint.detector.api.Severity;

import com.intellij.psi.PsiMethod;

import org.jetbrains.uast.UArrayAccessExpression;
import org.jetbrains.uast.UCallExpression;
import org.jetbrains.uast.UElement;
import org.jetbrains.uast.UExpression;
import org.jetbrains.uast.UParenthesizedExpression;
import org.jetbrains.uast.UQualifiedReferenceExpression;
import org.jetbrains.uast.UResolvable;

import java.util.Collections;
import java.util.List;

/**
 * Flags a write to a bridged value that nothing can observe afterwards.
 *
 * <pre>{@code
 * box.getLeaf().setLabel("x");         // flagged: the copy is discarded
 * box.getLeaf().bump();                // flagged: same, via a mutating method
 * lossy.getLeaves()[0].setLabel("x");  // flagged: elements are copies too
 *
 * Leaf l = box.getLeaf();
 * l.setLabel("x");                     // NOT flagged: l is a named copy,
 *                                      // and the write is visible through it
 * }</pre>
 *
 * <p>The rule is purely syntactic, which is what makes it exact. It needs no
 * dataflow and no name matching: the receiver is an unbound call to a method
 * the generator marked {@code @SwiftCopyingGetter}, and the callee is one it
 * marked {@code @SwiftMutating}. Binding the result first is correct code and
 * is left alone, because that is what {@code var l = box.leaf} does in Swift.
 */
public class DiscardedSwiftWriteDetector extends Detector implements Detector.UastScanner {

  private static final String COPYING_GETTER = "io.scade.swift4j.SwiftCopyingGetter";
  private static final String MUTATING = "io.scade.swift4j.SwiftMutating";

  public static final Issue ISSUE = Issue.create(
      "DiscardedSwiftWrite",
      "Write to a discarded Swift value",
      "This getter returns a copy of Swift-owned storage. Writing to that copy "
      + "without keeping it means the write goes nowhere: the copy is unreachable "
      + "as soon as the expression ends, and Swift never sees the change.\n"
      + "\n"
      + "To edit the owner, open a scope:\n"
      + "    box.unsafeWithLeaf(l -> l.setLabel(\"x\"));\n"
      + "\n"
      + "To work on a copy, bind it first, which is what `var l = box.leaf` does "
      + "in Swift:\n"
      + "    Leaf l = box.getLeaf();\n"
      + "    l.setLabel(\"x\");",
      Category.CORRECTNESS,
      8,
      Severity.ERROR,
      new Implementation(DiscardedSwiftWriteDetector.class, Scope.JAVA_FILE_SCOPE));

  @Override
  public List<Class<? extends UElement>> getApplicableUastTypes() {
    return Collections.singletonList(UCallExpression.class);
  }

  @Override
  public com.android.tools.lint.client.api.UElementHandler createUastHandler(JavaContext context) {
    return new com.android.tools.lint.client.api.UElementHandler() {
      @Override
      public void visitCallExpression(UCallExpression node) {
        check(context, node, node.resolve(), node.getReceiver());
      }

    };
  }

  private static void check(JavaContext context, UElement site, PsiMethod callee, UExpression receiver) {
    if (callee == null || !hasAnnotation(context, callee, MUTATING)) {
      return;
    }

    PsiMethod getter = originatingGetter(receiver);
    if (getter == null || !hasAnnotation(context, getter, COPYING_GETTER)) {
      return;
    }

    context.report(ISSUE, site, context.getLocation(site),
                   "`" + callee.getName() + "` writes to a copy returned by `"
                   + getter.getName() + "`, which is discarded. Use a scope to edit "
                   + "the owner, or assign the copy to a variable first.");
  }

  /**
   * Unwraps a receiver down to the method that produced it, seeing through
   * parentheses, array indexing, and Kotlin's property syntax. An index is
   * included because the elements of a copying getter's array are copies too.
   *
   * <p>Returns null for anything that is not a method call — notably a variable
   * reference, which is exactly the bound case this rule must not flag.
   */
  private static PsiMethod originatingGetter(UExpression expression) {
    UExpression current = unwrap(expression);
    while (current != null) {
      if (current instanceof UArrayAccessExpression) {
        current = unwrap(((UArrayAccessExpression) current).getReceiver());
        continue;
      }
      return resolveToMethod(current);
    }
    return null;
  }

  /** Strips parentheses and reduces a qualified reference to its selector. */
  private static UExpression unwrap(UExpression expression) {
    UExpression current = expression;
    while (true) {
      if (current instanceof UParenthesizedExpression) {
        current = ((UParenthesizedExpression) current).getExpression();
      } else if (current instanceof UQualifiedReferenceExpression) {
        current = ((UQualifiedReferenceExpression) current).getSelector();
      } else {
        return current;
      }
    }
  }

  /**
   * The method behind an expression: the callee of a call, or the accessor a
   * Kotlin property reference resolves to. Anything else — a local, a field —
   * yields null.
   */
  private static PsiMethod resolveToMethod(UExpression expression) {
    if (!(expression instanceof UResolvable)) {
      return null;
    }
    Object resolved = ((UResolvable) expression).resolve();
    return resolved instanceof PsiMethod ? (PsiMethod) resolved : null;
  }


  private static boolean hasAnnotation(JavaContext context, PsiMethod method, String name) {
    return context.getEvaluator().getAnnotation(method, name) != null;
  }
}
