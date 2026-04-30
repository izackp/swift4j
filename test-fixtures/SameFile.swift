import Swift4j

@jvm
public struct Outer {
  public let id: String
}

extension Outer {
  @jvm
  public struct InnerSameFile {
    public let v: String
  }
}
