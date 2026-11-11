struct BoundedRing<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var head = 0
    private let maximumCapacity: Int
    private(set) var count = 0

    init(capacity: Int, preallocate: Bool = true) {
        maximumCapacity = capacity
        storage = Array(repeating: nil, count: preallocate ? capacity : 0)
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
        if count == capacity, capacity < maximumCapacity {
            let retained = elements()
            storage = Array(repeating: nil, count: min(maximumCapacity, max(8, capacity * 2)))
            head = 0
            for (index, value) in retained.enumerated() {
                storage[index] = value
            }
        }
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
