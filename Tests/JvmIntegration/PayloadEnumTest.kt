import Swift4jFixtures.Color
import Swift4jFixtures.Shape
import Swift4jFixtures.Shaped

/**
 * Payload enums are the one peer swift4j emits as Kotlin rather than Java: a
 * sealed class with a nested class per case. That makes them unreachable from
 * the javac-only side of the harness, and it makes them the only peer whose
 * shape a Kotlin consumer sees differently from a Java one.
 *
 * Written in Kotlin deliberately — `when` exhaustiveness and property syntax
 * are part of what is being tested, and they are how the Android app actually
 * consumes these types.
 */
object PayloadEnumTest {

  private var failures = 0

  @JvmStatic
  fun main(args: Array<String>) {
    System.loadLibrary("Swift4jFixtures")

    section("payload enum construction")
    casesConstructAndExposeTheirPayload()
    casesAreDistinguishableByType()
    whenOverTheSealedHierarchyIsExhaustive()

    section("payload enum as a property")
    propertyRoundTripsPreservingTheCase()
    propertySetterReplacesTheCase()
    propertyReturnsAFreshPeerEachCall()
    payloadEnumPropertyHasNoScope()

    section("payload immutability")
    payloadAccessorsAreReadOnly()

    if (failures > 0) {
      println("\n$failures check(s) failed")
      System.exit(1)
    }
    println("\nall payload enum checks passed")
  }

  private fun casesConstructAndExposeTheirPayload() {
    check("circle exposes its radius", Shape.circle(5).radius == 5L)
    check("square exposes its side", Shape.square(7).side == 7L)
  }

  private fun casesAreDistinguishableByType() {
    val c: Shape = Shape.circle(1)
    val s: Shape = Shape.square(2)
    check("circle is not a square", c is Shape.circle && c !is Shape.square)
    check("square is not a circle", s is Shape.square && s !is Shape.circle)
  }

  /**
   * The reason a payload enum cannot be pointer-boxed like a struct: which case
   * a value holds is type information, and a bare address does not carry it.
   */
  private fun whenOverTheSealedHierarchyIsExhaustive() {
    val described = describe(Shape.circle(3))
    check("when matched the circle case", described == "circle:3")
    check("when matched the square case", describe(Shape.square(4)) == "square:4")
  }

  private fun describe(shape: Shape): String = when (shape) {
    is Shape.circle -> "circle:${shape.radius}"
    is Shape.square -> "square:${shape.side}"
  }

  private fun propertyRoundTripsPreservingTheCase() {
    val shaped = Shaped(Color.red, Shape.circle(3))
    val read = shaped.shape
    check("property preserved the case", read is Shape.circle)
    check("property preserved the payload", (read as Shape.circle).radius == 3L)
  }

  private fun propertySetterReplacesTheCase() {
    val shaped = Shaped(Color.red, Shape.circle(3))
    shaped.shape = Shape.square(9)

    val read = shaped.shape
    check("setter replaced the case", read is Shape.square)
    check("setter carried the new payload", (read as Shape.square).side == 9L)
  }

  private fun propertyReturnsAFreshPeerEachCall() {
    val shaped = Shaped(Color.red, Shape.circle(3))
    check("each read boxes a fresh peer", shaped.shape !== shaped.shape)
  }

  /**
   * A payload enum has no single peer to point at, so the CLI declares the
   * scoped-borrow native without exposing a wrapper — same treatment as Date,
   * for a different reason.
   */
  private fun payloadEnumPropertyHasNoScope() {
    val exposed = Shaped::class.java.methods.any { it.name == "unsafeWithShape" }
    check("payload enum property exposes no scope", !exposed)

    val declared = Shaped::class.java.declaredMethods.any { it.name == "unsafeWithShapeImpl" }
    check("payload enum property still declares its native", declared)
  }

  /**
   * Payload accessors are generated as `val`, so a case's payload cannot be
   * mutated in place at all. The write-loss question that applies to struct
   * properties does not arise here.
   */
  private fun payloadAccessorsAreReadOnly() {
    val setters = Shape.circle::class.java.methods.filter { it.name == "setRadius" }
    check("payload has no setter", setters.isEmpty())

    val getter = Shape.circle::class.java.methods.any { it.name == "getRadius" }
    check("payload has a getter", getter)
  }

  private fun section(name: String) = println("\n$name")

  private fun check(what: String, ok: Boolean) {
    println(if (ok) "  ok   $what" else "  FAIL $what")
    if (!ok) failures++
  }
}
