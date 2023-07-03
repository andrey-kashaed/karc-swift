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

import Kasync

public protocol Initable {
    init()
}

prefix internal func ~<T> (_ operation: @Sendable @escaping (T) async throws -> Void) -> @Sendable (Any) async throws -> Void {
    { @Sendable (_ t: Any) throws -> Void in try await operation(t as! T) }
}

internal extension Array {
    
    static func + (lhs: Self, rhs: Element?) -> Self {
        guard let rhs else { return lhs }
        return lhs + [rhs]
    }
    
    func getOrNil(_ index: Int) -> Element? {
        let isValidIndex = index >= 0 && index < count
        return isValidIndex ? self[index] : nil
    }
    
}

infix operator &&^: LogicalConjunctionPrecedence

internal extension Bool {
    
    static func &&^ (lhs: Bool, rhs: @autoclosure () async throws -> Bool) async rethrows -> Bool {
        if !lhs {
            return false
        }
        return try await rhs()
    }
    
}

infix operator ??^: NilCoalescingPrecedence

internal func ??^ <T>(optional: T?, defaultValue: () async throws -> T) async rethrows -> T {
    if let optional {
        return optional
    }
    return try await defaultValue()
}
