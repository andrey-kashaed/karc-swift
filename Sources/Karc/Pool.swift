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

fileprivate class Pool {
    var models: [String: AnyObject] = [:]
    var domains: [String: AnyObject] = [:]
    @Atomic fileprivate var defaultDomainHandler: ((String) -> Void)? = nil
}

fileprivate var pool: Pool = Pool()
fileprivate let lock = NSRecursiveLock()


public func setDefaultDomainHandler(_ handler: @escaping (String) -> Void) {
    pool.defaultDomainHandler = handler
}

public extension Domain {
    
    static var get: Self {
        get throws {
            let uid = String(describing: Self.self).replacingOccurrences(of: "Domain", with: "")
            return try lock.synchronized {
                try pool.domains[uid] as? Self ?? { throw NilUnwrappingError() }()
            }
        }
    }
    
    static func get(id: String) throws -> Self {
        let uid = String(describing: Self.self).replacingOccurrences(of: "Domain", with: "") + id
        return try lock.synchronized {
            try pool.domains[uid] as? Self ?? { throw NilUnwrappingError() }()
        }
    }
    
    static var getOrNil: Self? {
        let uid = String(describing: Self.self).replacingOccurrences(of: "Domain", with: "")
        return lock.synchronized {
            pool.domains[uid] as? Self
        }
    }
    
    static func getOrNil(id: String) -> Self? {
        let uid = String(describing: Self.self).replacingOccurrences(of: "Domain", with: "") + id
        return lock.synchronized {
            pool.domains[uid] as? Self
        }
    }
    
    static var getOrDefault: Self {
        let uid = String(describing: Self.self).replacingOccurrences(of: "Domain", with: "")
        return lock.synchronized {
            pool.domains[uid] as? Self
        } ?? {
            pool.defaultDomainHandler?(uid)
            return Self(state: State())
        }()
    }
    
    static func getOrDefault(id: String) -> Self {
        let uid = String(describing: Self.self).replacingOccurrences(of: "Domain", with: "") + id
        return lock.synchronized {
            pool.domains[uid] as? Self
        } ?? {
            pool.defaultDomainHandler?(uid)
            return Self(state: State())
        }()
    }
    
}

public extension Model {
    
    static func setUp(_ config: Config) {
        let uid = String(describing: Domain.self).replacingOccurrences(of: "Domain", with: "") + config.id
        lock.synchronized {
            let model = Self(config: config)
            pool.models[uid] = model
            pool.domains[uid] = model.domain
            model.setUp()
        }
    }
    
    static func tearDown(id: String = "") {
        let uid = String(describing: Domain.self).replacingOccurrences(of: "Domain", with: "") + id
        lock.synchronized {
            pool.domains.removeValue(forKey: uid)
            guard let model = pool.models.removeValue(forKey: uid) as? Self else {
                return
            }
            model.tearDown()
        }
    }
    
    static func submodel(id: String = "", state: State = State()) -> Submodel {
        Submodel(type: Self.self, id: id, state: state)
    }
    
}
