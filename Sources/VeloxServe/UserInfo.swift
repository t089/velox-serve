// borrowed from GRPC Swift

public struct UserInfo: CustomStringConvertible {
  private var storage: [AnyUserInfoKey: Any]

  /// A protocol for a key.
  public typealias Key = UserInfoKey

  /// Create an empty 'UserInfo'.
  public init() {
    self.storage = [:]
  }

  /// Allows values to be set and retrieved in a type safe way.
  public subscript<Key: UserInfoKey>(key: Key.Type) -> Key.Value? {
    get {
      if let anyValue = self.storage[AnyUserInfoKey(key)] {
        // The types must line up here.
        return (anyValue as! Key.Value)
      } else {
        return nil
      }
    }
    set {
      self.storage[AnyUserInfoKey(key)] = newValue
    }
  }

  public var description: String {
    return "[" + self.storage.map { key, value in
      "\(key): \(value)"
    }.joined(separator: ", ") + "]"
  }

  /// A `UserInfoKey` wrapper.
    private struct AnyUserInfoKey: Hashable, CustomStringConvertible {
    private let keyType: Any.Type

    var description: String {
      return String(describing: self.keyType.self)
    }

    init<Key: UserInfoKey>(_ keyType: Key.Type) {
      self.keyType = keyType
    }

    static func == (lhs: AnyUserInfoKey, rhs: AnyUserInfoKey) -> Bool {
      return ObjectIdentifier(lhs.keyType) == ObjectIdentifier(rhs.keyType)
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(self.keyType))
    }
  }
}

public protocol UserInfoKey {
  /// The type of identified by this key.
  associatedtype Value
}
