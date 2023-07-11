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
    
    open var optimizedScoping: Bool {
        true
    }
    
    open var parallelizedScoping: Bool {
        false
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
        logger.traceBlocking("[\(uid)] INIT")
    }
    
    deinit {
        logger.traceBlocking("[\(uid)] DEINIT")
    }
    
    final public func setUp() async {
        await willSetUp()
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
            let optimizedScoping = self.optimizedScoping
            while true {
                _ = try? await self.effectGate.process { (effects: [Effect]) -> [Event] in
                    let oldState = await self.domain.state
                    await self.willReduce(state: oldState, effects: effects)
                    let (newState, events) = self.combiner(state: oldState, effects: effects).reduce((oldState, [Event]())) { stateEvents, effect in
                        let (state, events) = self.reducer(state: stateEvents.0, effect: effect)
                        return (state, stateEvents.1 + events)
                    }
                    if oldState == newState && events.isEmpty { return [] }
                    self.domain.enableCommandSemaphore()
                    await self.domain.setState(state: newState)
                    if !optimizedScoping || !events.isEmpty {
                        await self.resolveScopesForState(scopes: &scopes, environ: self.environ, state: newState, interactor: interactor)
                    }
                    await self.domain.observeState()
                    self.domain.signalAndDisableCommandSemaphore()
                    await self.didReduce(state: newState, events: events)
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
            await self.deactivateScopes(scopes: scopes, environ: self.environ)
            await self.logger.trace("[\(self.uid)] Task is terminated")
        }
        await didSetUp()
    }
    
    final public func tearDown() async {
        await willTearDown()
        task?.cancel()
        task = nil
        domain.seal()
        effectGate.seal()
        await didTearDown()
    }
    
    open func willSetUp() async {
        await logger.trace("[\(uid)] WILL SET UP")
    }
    
    open func didSetUp() async {
        await logger.trace("[\(uid)] DID SET UP")
    }
    
    open func willTearDown() async {
        await logger.trace("[\(uid)] WILL TEAR DOWN")
    }
    
    open func didTearDown() async {
        await logger.trace("[\(uid)] DID TEAR DOWN")
    }
    
    open func willReduce(state: State, effects: [Effect]) async {
        await logger.trace("[\(uid)] Will reduce: \(effects)")
    }
    
    open func didReduce(state: State, events: [Event]) async {
        await logger.trace("[\(uid)] Did reduce: \(events)")
    }
    
    private func resolveScopesForState(scopes: inout [Scope], environ: Environ, state: State, interactor: Interactor) async {
        var newScopes = self.scopes(state, interactor)
        let p = scopes.partition(by: { scope in !newScopes.contains(where: { $0.uid == scope.uid }) })
        let oldScopes = scopes[p...]
        await deactivateScopes(scopes: oldScopes, environ: environ)
        scopes.removeLast(oldScopes.count)
        newScopes.removeAll { scope in scopes.contains(where: { $0.uid == scope.uid }) }
        await activateScopes(scopes: newScopes, environ: environ)
        scopes.append(contentsOf: newScopes)
    }
    
    private func activateScopes(scopes: some Collection<Scope>, environ: Environ) async {
        let modelUid = uid
        let logger = logger
        if parallelizedScoping {
            await withTaskGroup(of: Void.self) { taskGroup in
                scopes.forEach { scope in
                    let _ = taskGroup.addTaskUnlessCancelled {
                        await scope.activate(environ: environ, logger: logger, modelUid: modelUid)
                    }
                }
                await taskGroup.waitForAll()
            }
        } else {
            await scopes.forEachAsync { scope in
                await scope.activate(environ: environ, logger: logger, modelUid: modelUid)
            }
        }
    }
    
    private func deactivateScopes(scopes: some Collection<Scope>, environ: Environ) async {
        let modelUid = uid
        let logger = logger
        if parallelizedScoping {
            await withTaskGroup(of: Void.self) { taskGroup in
                scopes.forEach { scope in
                    let _ = taskGroup.addTaskUnlessCancelled {
                        await scope.deactivate(environ: environ, logger: logger, modelUid: modelUid)
                    }
                }
                await taskGroup.waitForAll()
            }
        } else {
            await scopes.forEachAsync {
                await $0.deactivate(environ: environ, logger: logger, modelUid: modelUid)
            }
        }
    }

}

public extension Model {
    
    static func submodel(id: Id = DefaultId.shared, state: State = State()) -> Submodel {
        Submodel(type: Self.self, id: id, state: state)
    }
    
    static func setUp(_ config: Config) async {
        let domainUid = Uid(tag: String(describing: Domain.self), id: config.id).asAny
        let model = Self(config: config)
        await Pool.shared.withTransaction {
            $0.setModelUnsafe(model, uid: domainUid)
            $0.setDomainUnsafe(model.domain, uid: domainUid)
        }
        await model.setUp()
    }
    
    static func tearDown(id: Id = DefaultId.shared) async {
        let domainUid = Uid(tag: String(describing: Domain.self), id: id).asAny
        guard let model = await Pool.shared.withTransaction({
            $0.removeDomainUnsafe(uid: domainUid)
            return $0.removeModelUnsafe(uid: domainUid) as? Self
        }) else {
            return
        }
        await model.tearDown()
    }
    
    static func setUpBlocking(_ config: Config) {
        runBlocking { await setUp(config) }
    }
    
    static func tearDownBlocking(id: Id = DefaultId.shared) {
        runBlocking { await tearDown(id: id) }
    }
    
}
