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

open class Domain<Id: Equatable & Hashable & Sendable, State: Equatable & Sendable & Initable, Command: Sendable, Event: Sendable>: @unchecked Sendable {
   
    public let id: Id
    @AtomicReference private var internalState: AtomicReference<State>.Safeguard
    private let commandGate = Gate<Command, Any>(mode: .transient, scheme: .anycast)
    internal let confinedCommandDrain: ConfinedDrain<Command, Any>
    internal let confinedCommandSource: ConfinedSource<Command, Any>
    private let eventGate = Gate<Event, Void>(mode: .retainable, scheme: .broadcast())
    internal let confinedEventDrain: ConfinedDrain<Event, Void>
    internal let confinedEventSource: ConfinedSource<Event, Void>
    
    private let commandSemaphore = Semaphore(initialPermits: 0)
    
    public required init(id: Id, state: State) {
        self.id = id
        _internalState = AtomicReference(state)
        confinedCommandDrain = commandGate.toDrain
        confinedCommandSource = commandGate.toSource
        confinedEventDrain = eventGate.toDrain
        confinedEventSource = eventGate.toSource
    }
    
    deinit {
        seal()
    }
    
    open func observe(state: State) {}
    
    public final var state: State {
        get async {
            await internalState^
        }
    }
    
    @discardableResult
    public final func send(_ command: Command) async throws -> Any {
        await awaitCommandSemaphoreIfEnabled()
        return try await commandGate.send(command)
    }
    
    public final func receive() async throws -> Event {
        try await eventGate.receive()
    }
    
    public final func receive<SubEvent>() async throws -> SubEvent {
        try await eventGate.receive()
    }
    
    public final func receiver() -> AsyncThrowingStream<Event, Error> {
        eventGate.receiver()
    }
    
    public final func receiver<SubEvent>() -> AsyncThrowingStream<SubEvent, Error> {
        eventGate.receiver()
    }
    
    internal func setState(state: State) async {
        await internalState =^ state
    }
    
    internal func observeState() async {
        await observe(state: internalState^)
    }
    
    public final var commandDrain: some Drain<Command, Any> {
        confinedCommandDrain
    }
    
    internal final var commandSource: some Source<Command, Any> {
        confinedCommandSource
    }
    
    internal final var eventDrain: some Drain<Event, Void> {
        confinedEventDrain
    }
    
    public final var eventSource: some Source<Event, Void> {
        confinedEventSource
    }
    
    internal func seal() {
        commandGate.seal(CancellationError())
        eventGate.seal(CancellationError())
        commandSemaphore.reset(enabled: false)
    }
    
    internal func enableCommandSemaphore() {
        commandSemaphore.reset(enabled: true)
    }

    internal func signalAndDisableCommandSemaphore() {
        commandSemaphore.withTransaction { semaphore in
            let awaitingParties = semaphore.awaitingParties
            try? semaphore.signal(permits: awaitingParties)
            semaphore.reset(enabled: false)
        }
    }

    private func awaitCommandSemaphoreIfEnabled() async {
        if commandSemaphore.isEnabled {
            try? await commandSemaphore.await()
        }
    }

}

public extension Domain {
    
    @discardableResult
    final func sendDetached(priority: TaskPriority? = Task.currentPriority, _ command: Command) -> Task<Any?, Never> {
        return Task.detached(priority: priority) { [weak self] in
            try? await self?.send(command)
        }
    }
    
}

public extension Domain {
    
    struct NoDomainFoundError: LocalizedError {
        let uid: AnyUid
        public var errorDescription: String? { "No domain found for uid: \(uid)" }
    }
    
    static func get(id: Id) async throws -> Self {
        let domainUid = Uid(tag: String(describing: Self.self), id: id).asAny
        return try await Pool.shared.getDomain(uid: domainUid) as? Self ?? { throw NoDomainFoundError(uid: domainUid) }()
    }
    
    static func getOrNil(id: Id) async -> Self? {
        let domainUid = Uid(tag: String(describing: Self.self), id: id).asAny
        return await Pool.shared.getDomain(uid: domainUid) as? Self
    }
    
    static func getOrDefault(id: Id) async -> Self {
        let domainUid = Uid(tag: String(describing: Self.self), id: id).asAny
        return await Pool.shared.getDomain(uid: domainUid) as? Self ?? {
            DefaultDomainHandler.notify(domainUid: domainUid)
            return Self(id: id, state: State())
        }()
    }
    
    static func getBlocking(id: Id) throws -> Self {
        try runBlocking { try await get(id: id) }
    }
    
    static func getOrNilBlocking(id: Id) -> Self? {
        runBlocking { await getOrNil(id: id) }
    }
    
    static func getOrDefaultBlocking(id: Id) -> Self {
        runBlocking { await getOrDefault(id: id) }
    }
    
}

public extension Domain where Id == DefaultId {
    
    static var get: Self {
        get async throws {
            let domainUid = Uid(tag: String(describing: Self.self), id: DefaultId.shared).asAny
            return try await Pool.shared.getDomain(uid: domainUid) as? Self ?? { throw NoDomainFoundError(uid: domainUid) }()
        }
    }
    
    static var getOrNil: Self? {
        get async {
            let domainUid = Uid(tag: String(describing: Self.self), id: DefaultId.shared).asAny
            return await Pool.shared.getDomain(uid: domainUid) as? Self
        }
    }
    
    static var getOrDefault: Self {
        get async {
            let domainUid = Uid(tag: String(describing: Self.self), id: DefaultId.shared).asAny
            return await Pool.shared.getDomain(uid: domainUid) as? Self ?? {
                DefaultDomainHandler.notify(domainUid: domainUid)
                return Self(id: DefaultId.shared, state: State())
            }()
        }
    }
    
    static var getBlocking: Self {
        get throws {
            try runBlocking { try await get }
        }
    }
    
    static var getOrNilBlocking: Self? {
        get {
            runBlocking { await getOrNil }
        }
    }
    
    static var getOrDefaultBlocking: Self {
        get {
            runBlocking { await getOrDefault }
        }
    }
    
}

public class DefaultDomainHandler {
    
    private static let shared = DefaultDomainHandler()
    
    @AtomicReference(nil as ((AnyUid) -> Void)?) private var callback
    
    private init() {}
    
    public static func setCallback(_ callback: @escaping (AnyUid) -> Void) {
        Task.detached(priority: .utility) {
            await shared.callback =^ callback
        }
    }
    
    fileprivate static func notify(domainUid: AnyUid) {
        Task.detached(priority: .utility) {
            (await shared.callback^)?(domainUid)
        }
    }
    
}
