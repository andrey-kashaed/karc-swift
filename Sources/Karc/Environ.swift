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

public final class Environ {
    
    private var configs = [String: Any]()
    
    private var dependencies = [String: Any]()
    
    private var resourceAcquireBlocks = [String: ([String: Any]) throws -> Any]()
    private var resourceReleaseBlocks = [String: (Any) throws -> Void]()
    private var resourcePermits = [String: Int]()
    private var resources = [String: Any]()
    
    private let lock = NSRecursiveLock()
    
    public init() {}
    
    public func setConfig<T>(key: String, value: T) {
        lock.synchronized {
            configs[key] = value
        }
    }
    
    public func removeConfig(key: String) {
        lock.synchronized {
            configs.removeValue(forKey: key)
        }
    }
    
    public func getConfig<T>(key: String) -> T? {
        lock.synchronized {
            configs[key] as? T
        }
    }

    public func register<T>(_ dependency: T) -> Environ {
        dependencies.merge(
            [String(describing: T.self): dependency],
            uniquingKeysWith: { (_, last) in last }
        )
        return self
    }

    public func resolve<T>() -> T {
        let key = String(describing: T.self)
        guard let dependency = dependencies[key] as? T else {
            fatalError("No dependency found for \(key)! must register a dependency before resolve.")
        }
        return dependency
    }
    
    public func resolve<T>(_ type: T.Type) -> T {
        let key = String(describing: T.self)
        guard let dependency = dependencies[key] as? T else {
            fatalError("No dependency found for \(key)! must register a dependency before resolve.")
        }
        return dependency
    }
    
    public func resolveOpt<T>() -> T? {
        let key = String(describing: T.self)
        return dependencies[key] as? T
    }
    
    public func resolveOpt<T>(_ type: T.Type) -> T? {
        let key = String(describing: T.self)
        return dependencies[key] as? T
    }
    
    public func register<T>(tag: String = "", acquire: @escaping ([String: Any]) throws -> T, release: @escaping (T) throws -> Void) -> Environ {
        let key = String(describing: T.self) + tag
        resourceAcquireBlocks.merge(
            [key: acquire],
            uniquingKeysWith: { (_, last) in last }
        )
        resourceReleaseBlocks.merge(
            [key: ~release],
            uniquingKeysWith: { (_, last) in last }
        )
        resourcePermits[key] = 0
        return self
    }
    
    public func acquire<T>(tag: String = "") throws -> T {
        try lock.synchronized {
            let key = String(describing: T.self) + tag
            guard let permit = resourcePermits[key] else {
                fatalError("No permit found for \(key)!")
            }
            if permit == 0 {
                guard let resourceAcquireBlock = resourceAcquireBlocks[key] else {
                    fatalError("No resource acquire block found for \(key)!")
                }
                resources[key] = try resourceAcquireBlock(configs)
            } else if permit < 0 {
                fatalError("Permit inconsistency for \(key)!")
            }
            resourcePermits[key] = permit + 1
            guard let resource = resources[key] as? T else {
                fatalError("No resource found for \(key)!")
            }
            return resource
        }
    }
    
    public func release<T>(_ type: T.Type, tag: String = "") throws {
        try lock.synchronized {
            let key = String(describing: T.self) + tag
            guard let permit = resourcePermits[key] else {
                fatalError("No permit found for \(key)!")
            }
            if permit == 1 {
                guard let resourceReleaseBlock = resourceReleaseBlocks[key] else {
                    fatalError("No resource release block found for \(key)!")
                }
                guard let resource = resources[key] as? T else {
                    fatalError("No resource found for \(key)!")
                }
                try resourceReleaseBlock(resource)
                resources.removeValue(forKey: key)
            } else if permit < 1 {
                fatalError("Permit inconsistency for \(key)!")
            }
            resourcePermits[key] = permit - 1
        }
    }
    
}

public extension Environ {
    
    @discardableResult
    func use<T, R>(tag: String = "", _ block: @escaping (T) async throws -> R) async throws -> R {
        let resource: T = try acquire(tag: tag)
        defer {
            try? release(T.self, tag: tag)
        }
        return try await block(resource)
    }
    
}

@propertyWrapper
public struct Inject<T> {
    
    unowned let environ: Environ
    
    public var wrappedValue: T {
        environ.resolve()
    }

    public init(_ environ: Environ) {
        self.environ = environ
    }
    
}

@propertyWrapper
public class Resource<R> {

    private let tag: String
    unowned let environ: Environ
    private var acquired: Bool = false
    
    private lazy var internalResource: R = {
        acquired = true
        return try! environ.acquire(tag: tag)
    }()
    
    public var wrappedValue: R {
        internalResource
    }
    
    public var projectedValue: Resource<R> {
        self
    }

    public init(_ environ: Environ, tag: String = "", lazy: Bool = true) {
        self.environ = environ
        self.tag = tag
        if !lazy {
            let _ = internalResource
        }
    }

    deinit {
        if acquired {
            try? environ.release(R.self, tag: tag)
        }
    }
    
}
