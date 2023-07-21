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

public struct Uid<Id>: Equatable & Hashable & Sendable & CustomStringConvertible where Id: Equatable & Hashable & Sendable {
    
    public let tag: String
    public let id: Id
    
    public init(tag: String, id: Id) {
        self.tag = tag
        self.id = id
    }
    
    public var description: String {
        "\(tag)-" + String(describing: id)
    }
    
}

public extension Uid {
    
    var asAny: AnyUid {
        AnyUid(uid: self)
    }
    
}

public struct AnyUid: Equatable & Hashable & Sendable & CustomStringConvertible {
    
    private let uid: any Sendable
    private let equals: @Sendable (Any) -> Bool
    private let combineIntoHasher: @Sendable (_ hasher: inout Hasher) -> Void
    public let tag: String
    
    init<Id>(uid: Uid<Id>) where Id: Equatable & Hashable & Sendable  {
        self.uid = uid
        equals =  { ($0 as? Uid<Id> == uid) }
        combineIntoHasher = { @Sendable in
            $0.combine(uid)
        }
        self.tag = uid.tag
    }
    
    public static func == (lhs: AnyUid, rhs: AnyUid) -> Bool {
        lhs.equals(rhs.uid)
    }
    
    public func hash(into hasher: inout Hasher) {
        combineIntoHasher(&hasher)
    }
    
    public var description: String {
        String(describing: uid)
    }
    
}

public struct DefaultId: Equatable & Hashable & Sendable & CustomStringConvertible {
    static public let shared = DefaultId()
    private init() {}
    public var description: String {
        "default"
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        true
    }
}
