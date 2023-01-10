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
        let key = String(describing: Self.self)
        return lock.synchronized {
            pool.domains[key] as! Self
        }
    }
    
    static func get(id: Any) -> Self {
        let key = String(describing: Self.self) + "\(id)"
        return lock.synchronized {
            pool.domains[key] as! Self
        }
    }
    
    static var getOrNil: Self? {
        let key = String(describing: Self.self)
        return lock.synchronized {
            pool.domains[key] as? Self
        }
    }
    
    static func getOrNil(id: Any) -> Self? {
        let key = String(describing: Self.self) + "\(id)"
        return lock.synchronized {
            pool.domains[key] as? Self
        }
    }
    
    static var getOrDefault: Self {
        let key = String(describing: Self.self)
        return lock.synchronized {
            pool.domains[key] as? Self
        } ?? {
            pool.defaultDomainHandler?(key)
            return Self(state: State())
        }()
    }
    
    static func getOrDefault(id: Any) -> Self {
        let key = String(describing: Self.self) + "\(id)"
        return lock.synchronized {
            pool.domains[key] as? Self
        } ?? {
            pool.defaultDomainHandler?(key)
            return Self(state: State())
        }()
    }
    
}

public extension Model {
    
    static func setUp(id: Any = "", _ config: Config) {
        let key = String(describing: Domain.self) + "\(id)"
        lock.synchronized {
            let model = Self(config: config)
            pool.models[key] = model
            pool.domains[key] = model.domain
            model.setUp()
        }
    }
    
    static func tearDown(id: Any = "") {
        let key = String(describing: Domain.self) + "\(id)"
        lock.synchronized {
            pool.domains.removeValue(forKey: key)
            guard let model = pool.models.removeValue(forKey: key) as? Self else {
                return
            }
            model.tearDown()
        }
    }
    
}
