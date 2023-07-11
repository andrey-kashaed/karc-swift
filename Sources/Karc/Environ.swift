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

public final class Environ: @unchecked Sendable {
    
    public struct NoResourceFoundError: LocalizedError {
        let resourceUid: AnyUid
        public var errorDescription: String? { "No resource found for uid: \(resourceUid)" }
    }
    
    public struct ResourceCounterInconsistencyError: LocalizedError {
        let resourceUid: AnyUid
        public var errorDescription: String? { "Resource counter inconsistency for uid: \(resourceUid)" }
    }
    
    public struct ResourceAcquireOperationInconsistencyError: LocalizedError {
        let resourceTag: String
        public var errorDescription: String? { "Resource acquire operation inconsistency for tag: \(resourceTag)" }
    }
    
    public struct ResourceReleaseOperationInconsistencyError: LocalizedError {
        let resourceTag: String
        public var errorDescription: String? { "Resource release operation inconsistency for tag: \(resourceTag)" }
    }
    
    private var configs = [String: Any]()
    private var resourceAcquireOperations = [String: @Sendable ([String: Any]) async throws -> Any]()
    private var resourceReleaseOperations = [String: @Sendable (Any) async throws -> Void]()
    private var resourceCounters = [AnyUid: Int]()
    private var resources = [AnyUid: Any]()
    
    private let mutex = Mutex()
    
    public init() {}
    
    public func setConfig<T>(key: String, value: T) async {
        await mutex.atomic {
            configs[key] = value
        }
    }
    
    public func removeConfig(key: String) async {
        await mutex.atomic {
            configs.removeValue(forKey: key)
        }
    }
    
    public func getConfig<T>(key: String) async -> T? {
        await mutex.atomic {
            configs[key] as? T
        }
    }
    
    public func register<R, G: Resource>(_ resourceType: R.Type, gatewayType: G.Type) -> Environ {
        register(
            acquire: { configs in
                let gateway = gatewayType.init()
                try await gateway.open(configs: configs)
                return gateway as! R
            },
            release: { resource in
                try await (resource as! Resource).close(configs: self.configs)
            }
        )
    }
    
    public func register<R>(acquire: @Sendable @escaping ([String: Any]) async throws -> R, release: @Sendable @escaping (R) async throws -> Void) -> Environ {
        let resourceTag = String(describing: R.self)
        resourceAcquireOperations.merge([resourceTag: acquire], uniquingKeysWith: { (_, last) in last })
        resourceReleaseOperations.merge([resourceTag: ~release], uniquingKeysWith: { (_, last) in last })
        return self
    }
    
    public func acquire<R, Id: Equatable & Hashable & Sendable>(_ resourceType: R.Type, id: Id = DefaultId.shared) async throws {
        try await mutex.atomic {
            let resourceTag = String(describing: R.self)
            let resourceUid = Uid(tag: resourceTag, id: id).asAny
            let counter = resourceCounters[resourceUid] ?? 0
            if counter == 0 {
                guard let resourceAcquireOperation = resourceAcquireOperations[resourceTag] else {
                    throw ResourceAcquireOperationInconsistencyError(resourceTag: resourceTag)
                }
                let resource: R = try await resourceAcquireOperation(configs) as! R
                resources[resourceUid] = resource
            } else if counter < 0 {
                throw ResourceCounterInconsistencyError(resourceUid: resourceUid)
            }
            resourceCounters[resourceUid] = counter + 1
        }
    }
    
    public func release<R, Id: Equatable & Hashable & Sendable>(_ resourceType: R.Type, id: Id = DefaultId.shared) async throws {
        try await mutex.atomic {
            let resourceTag = String(describing: R.self)
            let resourceUid = Uid(tag: resourceTag, id: id).asAny
            guard let counter = resourceCounters[resourceUid] else {
                throw ResourceCounterInconsistencyError(resourceUid: resourceUid)
            }
            if counter == 1 {
                guard let resourceReleaseOperation = resourceReleaseOperations[resourceTag] else {
                    throw ResourceReleaseOperationInconsistencyError(resourceTag: resourceTag)
                }
                guard let resource = resources[resourceUid] else {
                    throw NoResourceFoundError(resourceUid: resourceUid)
                }
                try await resourceReleaseOperation(resource)
                resources.removeValue(forKey: resourceUid)
            } else if counter < 1 {
                throw ResourceCounterInconsistencyError(resourceUid: resourceUid)
            }
            resourceCounters[resourceUid] = counter - 1
        }
    }
    
    public func resolve<R, Id: Equatable & Hashable & Sendable>(id: Id = DefaultId.shared) async throws -> R {
        try await mutex.atomic {
            let resourceUid = Uid(tag: String(describing: R.self), id: id).asAny
            guard let resource = resources[resourceUid] as? R else {
                throw NoResourceFoundError(resourceUid: resourceUid)
            }
            return resource
        }
    }
    
    public func resolve<R, Id: Equatable & Hashable & Sendable>(_ resourceType: R.Type, id: Id = DefaultId.shared) async throws -> R {
        try await resolve(id: id)
    }
    
}

public extension Environ {
    
    @discardableResult
    func use<R, T, Id: Equatable & Hashable & Sendable>(id: Id = DefaultId.shared, _ operation: @escaping (R) async throws -> T) async throws -> T {
        var result: Result<T, Error>? = nil
        do {
            try await acquire(R.self, id: id)
            let resource: R = try await resolve(id: id)
            result = .success(try await operation(resource))
        } catch {
            result = .failure(error)
        }
        try? await release(R.self, id: id)
        switch result! {
        case .success(let t):
            return t
        case .failure(let error):
            throw error
        }
    }
    
}

public protocol Resource: Sendable {
    init()
    func open(configs: [String: Any]) async throws
    func close(configs: [String: Any]) async throws
}

public extension Resource {
    func open(configs: [String: Any]) async throws {}
    func close(configs: [String: Any]) async throws {}
}

@propertyWrapper
public struct Inject<R, Id: Equatable & Hashable & Sendable>: Sendable {
    
    public final class Safeguard: @unchecked Sendable {
        
        private let environ: Environ
        private let id: Id
        
        fileprivate init(_ environ: Environ, id: Id) {
            self.environ = environ
            self.id = id
        }
        
        fileprivate func getResource() async throws -> R {
            try await environ.resolve(id: id)
        }
        
    }
    
    public struct BlockingSafeguard: Sendable {
        
        private var safeguard: Safeguard
        
        fileprivate init(safeguard: Safeguard) {
            self.safeguard = safeguard
        }
        
        fileprivate func getResource() throws -> R {
            try runBlocking { try await safeguard.getResource() }
        }
        
    }
    
    private var safeguard: Safeguard
    private var blockingSafeguard: BlockingSafeguard
    
    public var wrappedValue: Safeguard {
        safeguard
    }
    
    public var projectedValue: BlockingSafeguard {
        blockingSafeguard
    }
    
    public init(_ environ: Environ, id: Id = DefaultId.shared) {
        let safeguard = Safeguard(environ, id: id)
        let blockingSafeguard = BlockingSafeguard(safeguard: safeguard)
        self.safeguard = safeguard
        self.blockingSafeguard = blockingSafeguard
    }
    
}

@propertyWrapper
public struct Use<R, Id: Equatable & Hashable & Sendable>: Sendable {
    
    public final class Safeguard: @unchecked Sendable {
        
        private let environ: Environ
        private let id: Id
        @UncheckedReference private var acquired: Bool
        
        fileprivate let getResource: @Sendable () async throws -> R
        
        fileprivate init(_ environ: Environ, id: Id = DefaultId.shared) {
            @UncheckedReference var cachedResource: R? = nil
            @UncheckedReference var acquired = false
            @Atomic var getResource = { @Sendable () async throws -> R in
                if let resource = cachedResource {
                    return resource
                }
                try await environ.acquire(R.self, id: id)
                let resource: R = try await environ.resolve(id: id)
                $acquired =^ true
                $cachedResource =^ resource
                return resource
            }
            self.environ = environ
            self.id = id
            self._acquired = _acquired
            self.getResource = getResource
        }
        
        deinit {
            let environ = environ
            let id = id
            if acquired {
                Task.detached(priority: Task.currentPriority) {
                    try? await environ.release(R.self, id: id)
                }
            }
        }
        
    }
    
    public struct BlockingSafeguard: Sendable {
        
        private var safeguard: Safeguard
        
        fileprivate init(safeguard: Safeguard) {
            self.safeguard = safeguard
        }
        
        fileprivate func getResource() throws -> R {
            try runBlocking { try await safeguard.getResource() }
        }
        
    }
    
    private var safeguard: Safeguard
    private var blockingSafeguard: BlockingSafeguard
    
    public var wrappedValue: Safeguard {
        safeguard
    }
    
    public var projectedValue: BlockingSafeguard {
        blockingSafeguard
    }

    public init(_ environ: Environ, id: Id = DefaultId.shared, lazy: Bool = true) {
        let safeguard = Safeguard(environ, id: id)
        let blockingSafeguard = BlockingSafeguard(safeguard: safeguard)
        self.safeguard = safeguard
        self.blockingSafeguard = blockingSafeguard
        if !lazy {
            Task.detached(priority: Task.currentPriority) {
                let _ = try? await safeguard.getResource()
            }
        }
    }
    
}

postfix operator ^

public postfix func ^<R, Id: Equatable & Hashable & Sendable>(left: Inject<R, Id>.Safeguard) async throws -> R {
    try await left.getResource()
}

public postfix func ^<R, Id: Equatable & Hashable & Sendable>(left: Inject<R, Id>.BlockingSafeguard) throws -> R {
    try left.getResource()
}

public postfix func ^<R, Id: Equatable & Hashable & Sendable>(left: Use<R, Id>.Safeguard) async throws -> R {
    try await left.getResource()
}

public postfix func ^<R, Id: Equatable & Hashable & Sendable>(left: Use<R, Id>.BlockingSafeguard) throws -> R {
    try left.getResource()
}
