import Foundation
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

@Suite(.timeLimit(.minutes(1))) struct Network {}

/// A value shared between a test and the `@Sendable` closures it hands out.
final class Locked<Value>: @unchecked Sendable {  // `value` is only touched under `lock`
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func update<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}
