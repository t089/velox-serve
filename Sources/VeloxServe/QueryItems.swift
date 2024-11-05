@dynamicMemberLookup
public struct QueryItems {
    @usableFromInline
    final class _Storage {
        @usableFromInline
        var items: [(item: QueryItem, next: UInt16)] = []
        @usableFromInline
        var index: [Substring: (first: UInt16, last: UInt16)]? = [:]

        @usableFromInline
        init() {

        }

        @usableFromInline
        var ensureIndex: [Substring: (first: UInt16, last: UInt16)] {
            if let index = index {
                return index
            }
            var newIndex = [Substring: (first: UInt16, last: UInt16)]()
            for index in self.items.indices {
                let name = self.items[index].item.name
                self.items[index].next = .max
                if let lastIndex = newIndex[name]?.last {
                    self.items[Int(lastIndex)].next = UInt16(index)
                }
                newIndex[name, default: (first: UInt16(index), last: 0)].last = UInt16(index)
            }
            self.index = newIndex
            return newIndex
        }

        @usableFromInline
        func append(item: QueryItem) {
            let name = item.name
            let location = UInt16(self.items.endIndex)
            if let index = self.index?[name] {
                self.items[Int(index.last)].next = location
            }
            self.index?[name, default: (first: location, last: 0)].last = location
            self.items.append((item, .max))
        }
    }

    @usableFromInline
    let storage: _Storage = _Storage()

    public subscript (first name: String) -> String? {
        guard let index = self.storage.ensureIndex[name[...]]?.first else {
            return nil
        }
        return String(self.storage.items[Int(index)].item.value)
    }

    public subscript (last name: String) -> String? {
        guard let index = self.storage.ensureIndex[name[...]]?.last else {
            return nil
        }
        return String(self.storage.items[Int(index)].item.value)
    }

    public subscript (values name: String) -> [String] {
        guard let index = self.storage.ensureIndex[name[...]] else {
            return []
        }
        var i = index.first
        let last = index.last
        var values = [String]()
        repeat {
            let value = self.storage.items[Int(i)].item.value
            i = self.storage.items[Int(i)].next
            values.append(String(value))
        } while (i <= last)
        return values
    }

    public subscript (dynamicMember name: String) -> String? {
        get {
            self[first: name]
        }
    }

    @inlinable
    public init<S: StringProtocol>(parsing input: S) where S.SubSequence == Substring {
        let pairs = input.split(separator: "&", omittingEmptySubsequences: false)
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let item = QueryItem(encodedName: parts[0], encodedValue: parts.count == 2 ? parts[1] : "")
            self.storage.append(item: item)
        }
    }
}

@usableFromInline
struct QueryItem {
    @usableFromInline
    var encodedName: Substring
    @usableFromInline
    var encodedValue: Substring

    @usableFromInline
    init(encodedName: Substring, encodedValue: Substring) {
        self.encodedName = encodedName
        self.encodedValue = encodedValue
    }

    @usableFromInline
    var name: Substring {
        get {
            encodedName.removingURLPercentEncoding?[...] ?? encodedName
        }
    }

    @usableFromInline
    var value: Substring {
        get {
            encodedValue.removingURLPercentEncoding?[...] ?? encodedValue
        }
    }
}


extension UInt8 {
    init?(hex: UInt8) {
        switch hex {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): self = hex - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): self = hex - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): self = hex - UInt8(ascii: "a") + 10
            default: return nil
        }
    }
}


extension StringProtocol {
    var removingURLPercentEncoding: String? {
        let fastResult = self.utf8.withContiguousStorageIfAvailable { 
            VeloxServe.removingURLPercentEncoding(utf8Buffer: $0)
        }
        if let fastResult {
            return fastResult
        } else {
            return VeloxServe.removingURLPercentEncoding(utf8Buffer: self.utf8)
        }
    }
}


func removingURLPercentEncoding(utf8Buffer: some Collection<UInt8>) -> String? {
    let result : String? = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: utf8Buffer.count) { buffer  -> String? in
        var i = 0
        var byte: UInt8 = 0
        var hexDigitsRequired = 0
        for v in utf8Buffer {
            if v == UInt8(ascii: "%") {
                guard hexDigitsRequired == 0 else {
                    return nil
                }
                hexDigitsRequired = 2
            } else if v == UInt8(ascii: "+") {
                guard hexDigitsRequired == 0 else {
                    return nil
                }
                buffer[i] = UInt8(ascii: " ")
                i += 1
            } else if hexDigitsRequired > 0 {
                guard let hex = UInt8(hex: v) else {
                    return nil
                }
                if hexDigitsRequired == 2 {
                    byte = hex << 4
                } else if hexDigitsRequired == 1 {
                    byte += hex
                    buffer[i] = byte
                    i += 1
                    byte = 0
                }
                hexDigitsRequired -= 1
            } else {
                buffer[i] = v
                i += 1
            }
        }
        guard hexDigitsRequired == 0 else {
                return nil
            }
        return String(decoding: buffer[0..<i], as: UTF8.self)
    }
    return result
}