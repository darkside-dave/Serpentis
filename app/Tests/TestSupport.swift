import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "",
            file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else {
        throw TestFailure(description: "\(file):\(line): expectation failed\(message.isEmpty ? "" : ": \(message)")")
    }
}

func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = value else {
        throw TestFailure(description: "\(file):\(line): required value is nil")
    }
    return value
}

func expectModifierError(_ expected: ModifierError, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch let error as ModifierError { try expect(error == expected); return }
    throw TestFailure(description: "Expected \(expected), but the operation succeeded")
}

func waitUntil(_ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(condition(), "Timed out waiting for the operation")
}
