// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

private final class ConcurrentMapStorage<Value>: @unchecked Sendable {
    private var values: [Value?]
    private let lock = NSLock()

    init(count: Int) {
        values = [Value?](repeating: nil, count: count)
    }

    func store(_ value: Value, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func completedValues() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { value in
            guard let value else {
                preconditionFailure("Concurrent map did not produce a value for every input")
            }
            return value
        }
    }
}

extension Array where Element: Sendable {

    /// Returns an array containing the results of mapping the given closure over the sequence’s
    /// elements concurrently.
    ///
    /// - Parameters:
    ///   - queue: The queue for performing concurrent computations.
    ///            If the given queue is serial, the values are mapped in a serial fashion.
    ///            Pass `nil` to perform computations on the current queue.
    ///   - transform: the block to perform concurrent computations over the given element.
    /// - Returns: an array of concurrently computed values.
    func concurrentMap<U: Sendable>(
        queue: DispatchQueue?,
        _ transform: @escaping @Sendable (Element) -> U
    ) -> [U] {
        let storage = ConcurrentMapStorage<U>(count: count)
        let operation: @Sendable () -> Void = {
            DispatchQueue.concurrentPerform(iterations: self.count) { index in
                let value = transform(self[index])
                storage.store(value, at: index)
            }
        }

        if let queue {
            queue.sync(execute: operation)
        } else {
            operation()
        }

        return storage.completedValues()
    }
}
