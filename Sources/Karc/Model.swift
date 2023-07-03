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

open class Model<Domain: Sendable, Id: Equatable & Hashable & Sendable, State: Equatable & Sendable & Initable, Command: Sendable, Effect: Sendable, Event: Sendable>: @unchecked Sendable where Domain: Karc.Domain<Id, State, Command, Event> {
    
    public struct Config: Sendable {
        public let environ: Environ
        public let id: Id
        public let state: State
        public init(environ: Environ, id: Id = DefaultId.shared, state: State = State()) {
            self.environ = environ
            self.id = id
            self.state = state
        }
    }
    
    public struct Interactor: Sendable {
        public unowned let environ: Environ
        internal let stateGetter: @Sendable () async -> State
        internal let confinedCommandDrain: ConfinedDrain<Command, Any>
        internal let confinedCommandSource: ConfinedSource<Command, Any>
        internal let confinedEffectDrain: ConfinedDrain<[Effect], [Event]>
        internal let confinedEventSource: ConfinedSource<Event, Void>
        public var state: State {
            get async {
                await stateGetter()
            }
        }
        public var commandDrain: some Drain<Command, Any> {
            confinedCommandDrain
        }
        public var commandSource: some Source<Command, Any> {
            confinedCommandSource
        }
        public var effectDrain: some Drain<[Effect], [Event]> {
            confinedEffectDrain
        }
        public var eventSource: some Source<Event, Void> {
            confinedEventSource
        }
    }
    
    public let uid: AnyUid
    private let environ: Environ
    private var task: Task<Void, Never>?
    private lazy var logger: Logger = {
        Logger(logs: runBlocking { [self] in await logs(environ: environ) }, enabled: loggerEnabled)
    }()
    
    open var priority: TaskPriority? {
        nil
    }
    
    open func logs(environ: Environ) async -> [Log] {
        [DefaultLog.shared]
    }
    
    open var loggerEnabled: Bool {
        false
    }
    
    open func reducer(state: State, effect: Effect) -> (State, [Event]) {
        (state, [])
    }
    
    @ScopesBuilder
    open func scopes(_ state: State, _ interactor: Interactor) -> [Scope] {}
    
    open func combiner(state: State, effects: [Effect]) -> [Effect] {
        effects
    }
    
    internal let domain: Domain
    private let effectGate = Gate<[Effect], [Event]>(mode: .cumulative, scheme: .anycast)
    
    required public init(config: Config) {
        uid = Uid(tag: String(describing: Self.self), id: config.id).asAny
        environ = config.environ
        domain = Domain(id: config.id, state: config.state)
        logger.trace("[\(uid)] INIT")
    }
    
    deinit {
        logger.trace("[\(uid)] DEINIT")
    }
    
    final public func setUp() {
        willSetUp()
        domain.enableCommandSemaphore()
        task = Task.detached(priority: priority) {
            var scopes: [Scope] = []
            let interactor = Interactor(
                environ: self.environ,
                stateGetter: { [weak self] in await self?.domain.state ?? State() },
                confinedCommandDrain: self.domain.confinedCommandDrain,
                confinedCommandSource: self.domain.confinedCommandSource,
                confinedEffectDrain: self.effectGate.toDrain,
                confinedEventSource: self.domain.confinedEventSource
            )
            await self.resolveScopesForState(scopes: &scopes, environ: self.environ, state: self.domain.state, interactor: interactor)
            self.domain.signalAndDisableCommandSemaphore()
            while true {
                _ = try? await self.effectGate.process { (effects: [Effect]) -> [Event] in
                    let oldState = await self.domain.state
                    self.willReduce(state: oldState, effects: effects)
                    let (newState, events) = self.combiner(state: oldState, effects: effects).reduce((oldState, [Event]())) { stateEvents, effect in
                        let (state, events) = self.reducer(state: stateEvents.0, effect: effect)
                        return (state, stateEvents.1 + events)
                    }
                    if oldState == newState && events.isEmpty { return [] }
                    self.domain.enableCommandSemaphore()
                    await self.domain.setState(state: newState)
                    await self.resolveScopesForState(scopes: &scopes, environ: self.environ, state: newState, interactor: interactor)
                    await self.domain.observeState()
                    self.domain.signalAndDisableCommandSemaphore()
                    self.didReduce(state: newState, events: events)
                    let priority = Task.currentPriority
                    for event in events {
                        Task.detached(priority: priority) { [weak self] in
                            try? await self?.domain.eventDrain.send(event)
                        }
                    }
                    return events
                }
                if Task.isCancelled {
                    break
                }
            }
            await scopes.forEachAsync { scope in
                await scope.deactivate(environ: self.environ, logger: self.logger, modelUid: self.uid)
            }
            self.logger.trace("[\(self.uid)] Task is terminated")
        }
        didSetUp()
    }
    
    final public func tearDown() {
        willTearDown()
        task?.cancel()
        task = nil
        domain.seal()
        effectGate.seal()
        didTearDown()
    }
    
    open func willSetUp() {
        logger.trace("[\(uid)] WILL SET UP")
    }
    
    open func didSetUp() {
        logger.trace("[\(uid)] DID SET UP")
    }
    
    open func willTearDown() {
        logger.trace("[\(uid)] WILL TEAR DOWN")
    }
    
    open func didTearDown() {
        logger.trace("[\(uid)] DID TEAR DOWN")
    }
    
    open func willReduce(state: State, effects: [Effect]) {
        logger.trace("[\(uid)] Will reduce: \(effects)")
    }
    
    open func didReduce(state: State, events: [Event]) {
        logger.trace("[\(uid)] Did reduce: \(events)")
    }
    
    private func resolveScopesForState(scopes: inout [Scope], environ: Environ, state: State, interactor: Interactor) async {
        var newScopes = self.scopes(state, interactor)
        let p = scopes.partition(by: { scope in !newScopes.contains(where: { $0.uid == scope.uid }) })
        let oldScopes = scopes[p...]
        await oldScopes.forEachAsync {
            await $0.deactivate(environ: environ, logger: logger, modelUid: uid)
        }
        scopes.removeLast(oldScopes.count)
        newScopes.removeAll { scope in scopes.contains(where: { $0.uid == scope.uid }) }
        await newScopes.forEachAsync { scope in
            await scope.activate(environ: environ, logger: logger, modelUid: uid)
        }
        scopes.append(contentsOf: newScopes)
    }

}

public extension Model {
    
    static func submodel(id: Id = DefaultId.shared, state: State = State()) -> Submodel {
        Submodel(type: Self.self, id: id, state: state)
    }
    
    static func setUp(_ config: Config) async {
        let domainUid = Uid(tag: String(describing: Domain.self), id: config.id).asAny
        await Pool.shared.withTransaction {
            let model = Self(config: config)
            $0.setModelUnsafe(model, uid: domainUid)
            $0.setDomainUnsafe(model.domain, uid: domainUid)
            model.setUp()
        }
    }
    
    static func tearDown(id: Id = DefaultId.shared) async {
        let domainUid = Uid(tag: String(describing: Domain.self), id: id).asAny
        await Pool.shared.withTransaction {
            $0.removeDomainUnsafe(uid: domainUid)
            guard let model = $0.removeModelUnsafe(uid: domainUid) as? Self else {
                return
            }
            model.tearDown()
        }
    }
    
    static func setUpBlocking(_ config: Config) {
        runBlocking { await setUp(config) }
    }
    
    static func tearDownBlocking(id: Id = DefaultId.shared) {
        runBlocking { await tearDown(id: id) }
    }
    
}
