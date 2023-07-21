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
    
    public struct GateAlreadyOpenError: LocalizedError {
        let gateUid: AnyUid
        public var errorDescription: String? { "Gate already open for uid: \(gateUid)" }
    }
    
    public struct GateAlreadyClosedError: LocalizedError {
        let gateUid: AnyUid
        public var errorDescription: String? { "Gate already closed for uid: \(gateUid)" }
    }
    
    public struct NoGateFoundError: LocalizedError {
        let gateUid: AnyUid
        public var errorDescription: String? { "No gate found for uid: \(gateUid)" }
    }
    
    private var configs = [String: Any]()
    private var resourceAcquireOperations = [String: @Sendable ([String: Any]) async throws -> Any]()
    private var resourceReleaseOperations = [String: @Sendable (Any) async throws -> Void]()
    private var resourceCounters = [AnyUid: Int]()
    private var resources = [AnyUid: Any]()
    private let resourceMutex = Mutex()
    
    private var gates = [AnyUid: Any]()
    private let gateMutex = Mutex()
    
    public init() {}
    
    public func setConfig<T>(key: String, value: T) async {
        await resourceMutex.atomic {
            configs[key] = value
        }
    }
    
    public func removeConfig(key: String) async {
        await resourceMutex.atomic {
            configs.removeValue(forKey: key)
        }
    }
    
    public func getConfig<T>(key: String) async -> T? {
        await resourceMutex.atomic {
            configs[key] as? T
        }
    }
    
    public func registerResource<R, G: Resource>(_ resourceType: R.Type, gatewayType: G.Type) -> Environ {
        registerResource(
            acquire: { configs in
                let gateway = gatewayType.init()
                try await gateway.acquire(configs: configs)
                return gateway as! R
            },
            release: { resource in
                try await (resource as! Resource).release(configs: self.configs)
            }
        )
    }
    
    public func registerResource<R>(
        acquire: @Sendable @escaping ([String: Any]) async throws -> R,
        release: @Sendable @escaping (R) async throws -> Void
    ) -> Environ {
        let resourceTag = String(describing: R.self)
        resourceAcquireOperations.merge([resourceTag: acquire], uniquingKeysWith: { (_, last) in last })
        resourceReleaseOperations.merge([resourceTag: ~release], uniquingKeysWith: { (_, last) in last })
        return self
    }
    
    internal func acquireResource(uid: AnyUid) async throws {
        try await resourceMutex.atomic {
            let counter = resourceCounters[uid] ?? 0
            if counter == 0 {
                guard let resourceAcquireOperation = resourceAcquireOperations[uid.tag] else {
                    throw ResourceAcquireOperationInconsistencyError(resourceTag: uid.tag)
                }
                let resource = try await resourceAcquireOperation(configs)
                resources[uid] = resource
            } else if counter < 0 {
                throw ResourceCounterInconsistencyError(resourceUid: uid)
            }
            resourceCounters[uid] = counter + 1
        }
    }
    
    internal func releaseResource(uid: AnyUid) async throws {
        try await resourceMutex.atomic {
            guard let counter = resourceCounters[uid] else {
                throw ResourceCounterInconsistencyError(resourceUid: uid)
            }
            if counter == 1 {
                guard let resourceReleaseOperation = resourceReleaseOperations[uid.tag] else {
                    throw ResourceReleaseOperationInconsistencyError(resourceTag: uid.tag)
                }
                guard let resource = resources[uid] else {
                    throw NoResourceFoundError(resourceUid: uid)
                }
                try await resourceReleaseOperation(resource)
                resources.removeValue(forKey: uid)
            } else if counter < 1 {
                throw ResourceCounterInconsistencyError(resourceUid: uid)
            }
            resourceCounters[uid] = counter - 1
        }
    }
    
    internal func resource<R>(uid: AnyUid) async throws -> R {
        try await resourceMutex.atomic {
            guard let resource = resources[uid] as? R else {
                throw NoResourceFoundError(resourceUid: uid)
            }
            return resource
        }
    }
    
    internal func openGate<Input: Sendable, Output: Sendable>(
        uid: AnyUid,
        inputType: Input.Type,
        outputType: Output.Type,
        mode: Gate<Input, Output>.Mode,
        scheme: Gate<Input, Output>.Scheme,
        capacity: Int
    ) async throws {
        try await gateMutex.atomic {
            guard gates[uid] == nil else {
                throw GateAlreadyOpenError(gateUid: uid)
            }
            let gate = Gate<Input, Output>(mode: mode, scheme: scheme, capacity: capacity)
            gates[uid] = gate
        }
    }
    
    internal func closeGate<Input: Sendable, Output: Sendable>(
        uid: AnyUid,
        inputType: Input.Type,
        outputType: Output.Type
    ) async throws {
        guard let gate = await gateMutex.atomic({ gates.removeValue(forKey: uid) }) as? Gate<Input, Output> else {
            throw GateAlreadyClosedError(gateUid: uid)
        }
        gate.seal()
    }
    
    internal func gate<Input: Sendable, Output: Sendable>(
        uid: AnyUid,
        inputType: Input.Type,
        outputType: Output.Type
    ) async throws -> Gate<Input, Output> {
        guard let gate = await gateMutex.atomic({ gates[uid] }) as? Gate<Input, Output> else {
            throw NoGateFoundError(gateUid: uid)
        }
        return gate
    }
    
}

public protocol Resource: Sendable {
    init()
    func acquire(configs: [String: Any]) async throws
    func release(configs: [String: Any]) async throws
}

public extension Resource {
    func acquire(configs: [String: Any]) async throws {}
    func release(configs: [String: Any]) async throws {}
}

@propertyWrapper
public struct Inject<R>: Sendable {
    
    public final class Safeguard: @unchecked Sendable {
        
        private let environ: Environ
        private let resourceUid: AnyUid
        
        fileprivate init(_ environ: Environ, resourceUid: AnyUid) {
            self.environ = environ
            self.resourceUid = resourceUid
        }
        
        fileprivate func getResource() async throws -> R {
            try await environ.resource(uid: resourceUid)
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
    
    public init<Id: Equatable & Hashable & Sendable>(_ environ: Environ, id: Id = DefaultId.shared) {
        let safeguard = Safeguard(environ, resourceUid: Uid(tag: String(describing: R.self), id: id).asAny)
        let blockingSafeguard = BlockingSafeguard(safeguard: safeguard)
        self.safeguard = safeguard
        self.blockingSafeguard = blockingSafeguard
    }
    
}

@propertyWrapper
public struct Use<R>: Sendable {
    
    public final class Safeguard: @unchecked Sendable {
        
        private let environ: Environ
        private let resourceUid: AnyUid
        @UncheckedReference private var acquired: Bool
        
        fileprivate let getResource: @Sendable () async throws -> R
        
        fileprivate init(_ environ: Environ, resourceUid: AnyUid) {
            @UncheckedReference var cachedResource: R? = nil
            @UncheckedReference var acquired = false
            @Atomic var getResource = { @Sendable () async throws -> R in
                if let resource = cachedResource {
                    return resource
                }
                try await environ.acquireResource(uid: resourceUid)
                let resource: R = try await environ.resource(uid: resourceUid)
                $acquired =^ true
                $cachedResource =^ resource
                return resource
            }
            self.environ = environ
            self.resourceUid = resourceUid
            self._acquired = _acquired
            self.getResource = getResource
        }
        
        deinit {
            let environ = environ
            let resourceUid = resourceUid
            if acquired {
                Task.detached(priority: Task.currentPriority) {
                    try? await environ.releaseResource(uid: resourceUid)
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

    public init<Id: Equatable & Hashable & Sendable>(_ environ: Environ, id: Id = DefaultId.shared, lazy: Bool = true) {
        let safeguard = Safeguard(environ, resourceUid: Uid(tag: String(describing: R.self), id: id).asAny)
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

@propertyWrapper
public struct Connect<Input: Sendable, Output: Sendable>: Sendable {
    
    public final class Safeguard: @unchecked Sendable {
        
        private let environ: Environ
        private let gateUid: AnyUid
        
        fileprivate init(_ environ: Environ, gateUid: AnyUid) {
            self.environ = environ
            self.gateUid = gateUid
        }
        
        fileprivate func getGate() async throws -> Gate<Input, Output> {
            try await environ.gate(uid: gateUid, inputType: Input.self, outputType: Output.self)
        }
        
    }
    
    public struct BlockingSafeguard: Sendable {
        
        private var safeguard: Safeguard
        
        fileprivate init(safeguard: Safeguard) {
            self.safeguard = safeguard
        }
        
        fileprivate func getGate() throws -> Gate<Input, Output> {
            try runBlocking { try await safeguard.getGate() }
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
    
    public init<Id: Equatable & Hashable & Sendable>(_ environ: Environ, tag: String, id: Id = DefaultId.shared) {
        let safeguard = Safeguard(environ, gateUid: Uid(tag: tag, id: id).asAny)
        let blockingSafeguard = BlockingSafeguard(safeguard: safeguard)
        self.safeguard = safeguard
        self.blockingSafeguard = blockingSafeguard
    }
    
}

postfix operator ^

public postfix func ^<R>(left: Inject<R>.Safeguard) async throws -> R {
    try await left.getResource()
}

public postfix func ^<R>(left: Inject<R>.BlockingSafeguard) throws -> R {
    try left.getResource()
}

public postfix func ^<R>(left: Use<R>.Safeguard) async throws -> R {
    try await left.getResource()
}

public postfix func ^<R>(left: Use<R>.BlockingSafeguard) throws -> R {
    try left.getResource()
}

public postfix func ^<Input: Sendable, Output: Sendable>(left: Connect<Input, Output>.Safeguard) async throws -> Gate<Input, Output> {
    try await left.getGate()
}

public postfix func ^<Input: Sendable, Output: Sendable>(left: Connect<Input, Output>.BlockingSafeguard) throws -> Gate<Input, Output> {
    try left.getGate()
}
