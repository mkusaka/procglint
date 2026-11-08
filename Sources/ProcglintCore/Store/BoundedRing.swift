struct BoundedRing<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: capacity)
    }

    var first: Element? {
        count == 0 ? nil : storage[head]
    }

    var last: Element? {
        count == 0 ? nil : storage[(head + count - 1) % capacity]
    }

    var capacity: Int {
        storage.count
    }

    mutating func append(_ element: Element) {
        let index = (head + count) % capacity
        storage[index] = element
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
    }

    mutating func removeFirst() {
        guard count > 0 else { return }
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
    }

    func elements() -> [Element] {
        (0 ..< count).compactMap { storage[(head + $0) % capacity] }
    }
}
