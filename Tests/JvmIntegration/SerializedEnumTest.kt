import Swift4jFixtures.Reading
import Swift4jFixtures.Sample

/**
 * A serialized payload enum: the sealed hierarchy is the same shape a consumer
 * already knew, but each case class stores its payload instead of reaching
 * through a pointer for it.
 *
 * Kotlin, for the same reason as PayloadEnumTest — the peer is Kotlin, and
 * `when` exhaustiveness over the hierarchy is part of what has to keep working.
 */
object SerializedEnumTest {

  private var failures = 0

  @JvmStatic
  fun main(args: Array<String>) {
    System.loadLibrary("Swift4jFixtures")

    section("construction and payload")
    casesCarryTheirOwnPayload()
    optionalPayloadCrossesBothWays()
    whenOverTheHierarchyIsExhaustive()

    section("no pointer is involved")
    hierarchyHoldsNoPointer()
    casesDeclareNoNatives()

    section("crossing into Swift and back")
    swiftReadsTheCaseItWasGiven()
    swiftBuildsACaseJavaCanRead()
    nestedInASerializedValue()

    if (failures > 0) {
      println("\n$failures check(s) failed")
      System.exit(1)
    }
    println("\nall serialized enum checks passed")
  }

  private fun casesCarryTheirOwnPayload() {
    check("payload-free case is an object", Reading.none === Reading.none)
    check("single payload reads back", Reading.count(5).value == 5L)
    val l = Reading.labelled("size", 7)
    check("first of two payloads reads back", l.name == "size")
    check("second of two payloads reads back", l.value == 7L)
  }

  private fun optionalPayloadCrossesBothWays() {
    check("present optional reads back", Reading.optional("here").note == "here")
    check("absent optional reads back null", Reading.optional(null).note == null)
  }

  private fun whenOverTheHierarchyIsExhaustive() {
    check("when matched count", describe(Reading.count(2)) == "count:2")
    check("when matched none", describe(Reading.none) == "none")
  }

  private fun describe(r: Reading): String = when (r) {
    is Reading.none -> "none"
    is Reading.count -> "count:${r.value}"
    is Reading.labelled -> "labelled:${r.name}:${r.value}"
    is Reading.optional -> "optional:${r.note}"
  }

  /**
   * The point of the whole exercise: a serialized case is Java data. If any
   * case still boxed a SwiftPtr, the JVM would again be unable to see what the
   * value costs.
   */
  private fun hierarchyHoldsNoPointer() {
    val fields = Reading.count::class.java.declaredFields.map { it.type.simpleName }
    check("no case field is a SwiftPtr", !fields.contains("SwiftPtr"))

    val ptrAccessor = Reading::class.java.declaredMethods.any { it.name == "_ptr" }
    check("hierarchy exposes no _ptr", !ptrAccessor)
  }

  private fun casesDeclareNoNatives() {
    val natives = (Reading::class.java.declaredMethods + Reading.count::class.java.declaredMethods)
      .filter { java.lang.reflect.Modifier.isNative(it.modifiers) }
    check("no natives are declared", natives.isEmpty())
  }

  private fun swiftReadsTheCaseItWasGiven() {
    check("Swift saw the payload-free case", Sample(1, Reading.none).describe() == "1:none")
    check("Swift saw the single payload", Sample(2, Reading.count(9)).describe() == "2:count(9)")
    check("Swift saw both payloads",
          Sample(3, Reading.labelled("w", 4)).describe() == "3:labelled(w,4)")
    check("Swift saw a present optional",
          Sample(4, Reading.optional("hi")).describe() == "4:optional(hi)")
    check("Swift saw an absent optional",
          Sample(5, Reading.optional(null)).describe() == "5:optional(nil)")
  }

  private fun swiftBuildsACaseJavaCanRead() {
    val built = Sample.make(3)
    check("Swift built the labelled case", built is Reading.labelled)
    check("with its name", (built as Reading.labelled).name == "n3")
    check("with its value", built.value == 3L)
    check("Swift built the payload-free case", Sample.make(-1) is Reading.none)
  }

  private fun nestedInASerializedValue() {
    val s = Sample(8, Reading.count(6))
    val read = s.reading
    check("the nested enum survives the containing value", read is Reading.count)
    check("with its payload", (read as Reading.count).value == 6L)
  }

  private fun section(name: String) = println("\n$name")

  private fun check(what: String, ok: Boolean) {
    println(if (ok) "  ok   $what" else "  FAIL $what")
    if (!ok) failures++
  }
}
