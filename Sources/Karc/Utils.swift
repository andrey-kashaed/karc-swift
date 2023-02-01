//
// DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
//
// Copyright (c) 2023 Andrey Kashaed. All rights reserved.
//
// The contents of this file are subject to the terms of the
// Common Development and Distribution License 1.0 (the "License").
// You may not use this file except in compliance with the License.
//
// You can obtain a copy of the License at
// https://opensource.org/licenses/CDDL-1.0 or LICENSE.txt.
//

import Foundation
import Kasync

public protocol Initable {
    init()
}

public protocol Loggable {
    func error(_ message: String)
    func warn(_ message: String)
    func info(_ message: String)
    func debug(_ message: String)
}

public typealias IO<I, O> = (I) async throws -> O

public func % <I, O>(
    f: @escaping IO<I, O>,
    c: @escaping (Error, I) async -> Void
) -> IO<I, O> {
    { i in
        do {
            return try await f(i)
        } catch {
            await c(error, i)
            throw error
        }
    }
}

public struct NilUnwrappingError: LocalizedError {
    public var errorDescription: String? { "Unexpectedly found nil while unwrapping an Optional value" }
}

internal extension NSLocking {
    @discardableResult
    @inline(__always)
    func synchronized<T>(_ closure: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try closure()
    }
}

prefix internal func ~<T> (_ block: @escaping (T) throws -> Void) -> (Any) throws -> Void {
    { (_ t: Any) throws -> Void in try block(t as! T) }
}

@propertyWrapper
internal struct Atomic<Value> {

    private var value: Value
    private let lock = NSLock()

    public init(wrappedValue value: Value) {
        self.value = value
    }

    public var wrappedValue: Value {
      get {
          lock.lock()
          defer { lock.unlock() }
          return value
      }
      set {
          lock.lock()
          defer { lock.unlock() }
          value = newValue
      }
    }
    
}

internal extension Array {
    
    func getOrNil(_ index: Int) -> Element? {
        let isValidIndex = index >= 0 && index < count
        return isValidIndex ? self[index] : nil
    }
    
}

internal extension Sequence {
    
    func forEachAsync(_ operation: (Element) async throws -> Void) async rethrows {
        for element in self {
            try await operation(element)
        }
    }
    
}

internal extension Date {
    
    var millisecondsSince1970: Int64 {
        Int64((self.timeIntervalSince1970 * 1000.0).rounded())
    }
    
    init(milliseconds: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
    
    var defaultFormat: String {
        defaultDateFormatter.string(from: self)
    }
    
}

fileprivate let defaultDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df
}()
