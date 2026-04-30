import Swift4j

@jvm
public enum MyEnum {
  case a
  case b

  @jvm
  public struct Nested {
    public let v: String
  }
}
