package io.scade.swift4j.lint;

import static com.android.tools.lint.checks.infrastructure.TestFiles.java;
import static com.android.tools.lint.checks.infrastructure.TestLintTask.lint;

import com.android.tools.lint.checks.infrastructure.TestFile;

import org.junit.Test;

/**
 * The distinction the rule exists to draw: an unbound copy is a defect, a bound
 * one is correct Swift value semantics.
 */
public class DiscardedSwiftWriteDetectorTest {

  private static final TestFile ANNOTATIONS = java(""
      + "package io.scade.swift4j;\n"
      + "public @interface SwiftCopyingGetter {}\n");

  private static final TestFile MUTATING = java(""
      + "package io.scade.swift4j;\n"
      + "public @interface SwiftMutating {}\n");

  private static final TestFile PEERS = java(""
      + "package peers;\n"
      + "public class Leaf {\n"
      + "  @io.scade.swift4j.SwiftMutating public void setLabel(String v) {}\n"
      + "  @io.scade.swift4j.SwiftMutating public void bump() {}\n"
      + "  public String getLabel() { return null; }\n"
      + "}\n");

  private static final TestFile BOX = java(""
      + "package peers;\n"
      + "public class Box {\n"
      + "  @io.scade.swift4j.SwiftCopyingGetter public Leaf getLeaf() { return null; }\n"
      + "  @io.scade.swift4j.SwiftCopyingGetter public Leaf[] getLeaves() { return null; }\n"
      + "  public String getTag() { return null; }\n"
      + "}\n");

  @Test
  public void flagsWriteToADiscardedCopy() {
    lint()
        .files(ANNOTATIONS, MUTATING, PEERS, BOX, java(""
            + "package app;\n"
            + "import peers.Box;\n"
            + "public class Use {\n"
            + "  void run(Box box) {\n"
            + "    box.getLeaf().setLabel(\"x\");\n"
            + "  }\n"
            + "}\n"))
        .issues(DiscardedSwiftWriteDetector.ISSUE)
        .run()
        .expectErrorCount(1);
  }

  @Test
  public void flagsMutatingMethodOnADiscardedCopy() {
    lint()
        .files(ANNOTATIONS, MUTATING, PEERS, BOX, java(""
            + "package app;\n"
            + "import peers.Box;\n"
            + "public class Use {\n"
            + "  void run(Box box) {\n"
            + "    box.getLeaf().bump();\n"
            + "  }\n"
            + "}\n"))
        .issues(DiscardedSwiftWriteDetector.ISSUE)
        .run()
        .expectErrorCount(1);
  }

  /** The elements of a copying getter's array are copies as well. */
  @Test
  public void seesThroughArrayIndexing() {
    lint()
        .files(ANNOTATIONS, MUTATING, PEERS, BOX, java(""
            + "package app;\n"
            + "import peers.Box;\n"
            + "public class Use {\n"
            + "  void run(Box box) {\n"
            + "    box.getLeaves()[0].setLabel(\"x\");\n"
            + "  }\n"
            + "}\n"))
        .issues(DiscardedSwiftWriteDetector.ISSUE)
        .run()
        .expectErrorCount(1);
  }

  /**
   * The case that must stay clean. `l` is a named copy and the write is visible
   * through it, exactly as `var l = box.leaf` behaves in Swift. Flagging this
   * would make the rule worse than useless.
   */
  @Test
  public void allowsWriteToABoundCopy() {
    lint()
        .files(ANNOTATIONS, MUTATING, PEERS, BOX, java(""
            + "package app;\n"
            + "import peers.Box;\n"
            + "import peers.Leaf;\n"
            + "public class Use {\n"
            + "  void run(Box box) {\n"
            + "    Leaf l = box.getLeaf();\n"
            + "    l.setLabel(\"x\");\n"
            + "  }\n"
            + "}\n"))
        .issues(DiscardedSwiftWriteDetector.ISSUE)
        .run()
        .expectClean();
  }

  @Test
  public void allowsReadFromADiscardedCopy() {
    lint()
        .files(ANNOTATIONS, MUTATING, PEERS, BOX, java(""
            + "package app;\n"
            + "import peers.Box;\n"
            + "public class Use {\n"
            + "  String run(Box box) {\n"
            + "    return box.getLeaf().getLabel();\n"
            + "  }\n"
            + "}\n"))
        .issues(DiscardedSwiftWriteDetector.ISSUE)
        .run()
        .expectClean();
  }

  /** An unannotated getter returns nothing that could be lost. */
  @Test
  public void allowsMutationOffAnUnmarkedGetter() {
    lint()
        .files(ANNOTATIONS, MUTATING, PEERS, BOX, java(""
            + "package app;\n"
            + "import peers.Box;\n"
            + "public class Use {\n"
            + "  int run(Box box) {\n"
            + "    return box.getTag().length();\n"
            + "  }\n"
            + "}\n"))
        .issues(DiscardedSwiftWriteDetector.ISSUE)
        .run()
        .expectClean();
  }
}
