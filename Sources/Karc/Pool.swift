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

internal final class Pool {
    
    internal static let shared = Pool()
    private var models: [AnyUid: AnyObject] = [:]
    private var domains: [AnyUid: AnyObject] = [:]
    private let mutex = Mutex()
    
    private init() {}
    
    internal func withTransaction<T>(_ transaction: (Pool) throws -> T) async rethrows -> T {
        try await mutex.atomic { try transaction(self) }
    }
    
    internal func getModel(uid: AnyUid) async -> AnyObject? {
        await mutex.atomic { models[uid] }
    }
    
    internal func setModel(_ model: AnyObject, uid: AnyUid) async {
        await mutex.atomic { models[uid] = model }
    }
    
    @discardableResult
    internal func removeModel(uid: AnyUid) async -> AnyObject? {
        await mutex.atomic { models.removeValue(forKey: uid) }
    }
    
    internal func getModelUnsafe(uid: AnyUid) -> AnyObject? {
        models[uid]
    }
    
    internal func setModelUnsafe(_ model: AnyObject, uid: AnyUid) {
        models[uid] = model
    }
    
    @discardableResult
    internal func removeModelUnsafe(uid: AnyUid) -> AnyObject? {
        models.removeValue(forKey: uid)
    }
    
    internal func getDomain(uid: AnyUid) async -> AnyObject? {
        await mutex.atomic { domains[uid] }
    }
    
    internal func setDomain(_ domain: AnyObject, uid: AnyUid) async {
        await mutex.atomic { domains[uid] = domain }
    }
    
    @discardableResult
    internal func removeDomain(uid: AnyUid) async -> AnyObject? {
        await mutex.atomic { domains.removeValue(forKey: uid) }
    }
    
    internal func getDomainUnsafe(uid: AnyUid) -> AnyObject? {
        domains[uid]
    }
    
    internal func setDomainUnsafe(_ domain: AnyObject, uid: AnyUid) {
        domains[uid] = domain
    }
    
    @discardableResult
    internal func removeDomainUnsafe(uid: AnyUid) -> AnyObject? {
        domains.removeValue(forKey: uid)
    }
    
}
