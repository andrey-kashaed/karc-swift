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

public typealias Combiner<State, Element> = (State, [Element]) -> [Element]

public typealias Reducer<State, Input, Output> = (State, Input) -> (State, [Output])

open class Model<Domain, State: Equatable & Initable, Command, Effect, Event> where Domain: Karc.Domain<State, Command, Event> {
    
    public struct Config {
        var environ: Environ
        public var id: String
        public var state: State
        public init(environ: Environ, id: String = "", state: State = State()) {
            self.environ = environ
            self.id = id
            self.state = state
        }
    }
    
    public let uid: String
    public let id: String
    private let environ: Environ
    private var task: Task<Void, Never>?
    
    open func loggable(environ: Environ) -> Loggable? {
        nil
    }
    
    open var reducer: Reducer<State, Effect, Event> {
        fatalError("This method must be overridden")
    }
    
    open func scopes() -> [Scope<State, Command, Effect, Event>] {
        []
    }
    
    open var effectCombiner: Combiner<State, Effect> {
        { _, effects in effects }
    }
    
    internal let domain: Domain
    private let effectGate = Gate<[Effect], [Event]>(mode: Gate.Mode.cumulative(), scheme: .anycast)
    
    required public init(config: Config) {
        uid = String(describing: Domain.self).replacingOccurrences(of: "Domain", with: "") + config.id
        id = config.id
        environ = config.environ
        domain = Domain(state: config.state)
        if let loggable = loggable(environ: environ) {
            loggable.debug("[\(uid)] INIT")
        }
    }
    
    deinit {
        if let loggable = loggable(environ: environ) {
            loggable.debug("[\(uid)] DEINIT")
        }
    }
    
    final public func setUp() {
        let loggable = loggable(environ: environ)
        loggable?.debug("[\(uid)] SET UP")
        domain.resetCommandBarrier()
        task = Task {
            let scopes = self.scopes()
            let interactor = Interactor(
                environ: self.environ,
                stateGetter: { [weak self] in await self?.domain.state ?? State() },
                commandSource: self.domain.commandSource,
                commandDrain: self.domain.commandDrain,
                effectDrain: self.effectGate.asDrain,
                eventSource: self.domain.eventSource
            )
            await self.activateScopesOnDemand(scopes: scopes, environ: self.environ, state: self.domain.state, interactor: interactor)
            self.domain.signalCommandBarrier()
            do {
                while true {
                    try await self.effectGate.process { (effects: [Effect]) -> [Event] in
                        loggable?.info("[\(uid)] Will reduce: \(effects)")
                        let oldState = await self.domain.state
                        self.willReduce(state: oldState, effects: effects)
                        let (newState, events) = self.effectCombiner(oldState, effects).reduce((oldState, [Event]())) { stateEvents, effect in
                            let (state, events) = self.reducer(stateEvents.0, effect)
                            return (state, stateEvents.1 + events)
                        }
                        if oldState == newState && events.isEmpty { return [] }
                        self.domain.resetCommandBarrier()
                        await self.domain.setState(state: newState)
                        //loggable?.info("[\(id)] state: \(state)")
                        await self.activateScopesOnDemand(scopes: scopes, environ: self.environ, state: newState, interactor: interactor)
                        self.domain.signalCommandBarrier()
                        loggable?.info("[\(uid)] Did reduce: \(events)")
                        self.didReduce(state: newState, events: events)
                        self.deactivateScopesOnDemand(scopes: scopes, environ: self.environ, state: newState)
                        for event in events {
                            Task { [weak self] in
                                try? await self?.domain.eventDrain.send(event)
                            }
                        }
                        return events
                    }
                }
            } catch {
                switch error {
                case is CancellationError:
                    loggable?.debug("[\(uid)] Effect gate is canceled")
                default:
                    loggable?.error("[\(uid)] Effect gate critical error: \(error.localizedDescription)")
                }
            }
            await self.deactivateScopesOnDemand(scopes: scopes, environ: self.environ, state: self.domain.state, force: true)
        }
        onSetUp()
    }
    
    final public func tearDown() {
        loggable(environ: environ)?.debug("[\(uid)] TEAR DOWN")
        task?.cancel()
        task = nil
        domain.seal()
        effectGate.seal()
        onTearDown()
    }
    
    open func onSetUp() {}
    
    open func onTearDown() {}
    
    open func willReduce(state: State, effects: [Effect]) {}
    
    open func didReduce(state: State, events: [Event]) {}
    
    private func activateScopesOnDemand(scopes: [Scope<State, Command, Effect, Event>], environ: Environ, state: State, interactor: Interactor<State, Command, Effect, Event>) async {
        await scopes.forEachAsync { scope in
            await scope.activateOnDemand(environ: environ, loggable: loggable(environ: environ), modelUid: uid, modelId: id, state: state, interactor: interactor)
        }
    }
    
    private func deactivateScopesOnDemand(scopes: [Scope<State, Command, Effect, Event>], environ: Environ, state: State, force: Bool = false) {
        scopes.forEach { scope in
            scope.deactivateOnDemand(environ: environ, state: state, force: force)
        }
    }

}
