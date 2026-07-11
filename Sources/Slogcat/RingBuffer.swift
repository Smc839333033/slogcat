import Foundation

/// Fixed-capacity circular buffer. O(1) append, drops oldest when full.
/// Used to bound memory for both raw and filtered log buffers.
struct RingBuffer<T>: @unchecked Sendable {
    private var storage: [T?]
    private var head: Int
    private(set) var count: Int
    let capacity: Int

    init(capacity: Int) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.storage = Array(repeating: nil, count: cap)
        self.head = 0
        self.count = 0
    }

    mutating func append(_ element: T) {
        if count < capacity {
            storage[(head + count) % capacity] = element
            count += 1
        } else {
            // overwrite oldest, advance head
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func clear() {
        for i in 0..<storage.count { storage[i] = nil }
        head = 0
        count = 0
    }

    /// Returns all live elements in insertion order (oldest → newest).
    func allElements() -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            if let v = storage[(head + i) % capacity] {
                result.append(v)
            }
        }
        return result
    }

    /// Returns the last `k` live elements (newest), in insertion order.
    func tail(_ k: Int) -> [T] {
        let n = Swift.min(k, count)
        guard n > 0 else { return [] }
        var result: [T] = []
        result.reserveCapacity(n)
        let start = count - n
        for i in 0..<n {
            if let v = storage[(head + start + i) % capacity] {
                result.append(v)
            }
        }
        return result
    }
}
