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

public typealias Scopes<State: Equatable, Command, Effect, Event> = (Interactor<State, Command, Effect, Event>) -> [Scope<State>]

open class Model<Domain, State: Equatable & Initable, Command, Effect, Event> where Domain: Karc.Domain<State, Command, Event> {
    
    public struct Config {
        var environ: Environ
        public var state: State
        var receiver: ((State, Event, AnyDrain<Command, Any>) async throws -> Void)?
        public init(environ: Environ, state: State = State(), receiver: ((State, Event, AnyDrain<Command, Any>) async throws -> Void)? = nil) {
            self.environ = environ
            self.state = state
            self.receiver = receiver
        }
    }
    
    private let environ: Environ
    private let receiver: ((State, Event, AnyDrain<Command, Any>) async throws -> Void)?
    private var task: Task<Void, Never>?
    
    open var id: String {
        String(describing: type(of: self))
    }
    
    open func loggable(environ: Environ) -> Loggable? {
        nil
    }
    
    open var reducer: Reducer<State, Effect, Event> {
        fatalError("This method must be overridden")
    }
    
    open var scopes: Scopes<State, Command, Effect, Event> {
        { _ in
            []
        }
    }
    
    open var effectCombiner: Combiner<State, Effect> {
        { _, effects in effects }
    }
    
    internal let domain: Domain
    private let effectGate = Gate<[Effect], [Event]>(mode: Gate.Mode.cumulative(), scheme: .anycast)
    
    required public init(config: Config) {
        environ = config.environ
        domain = Domain(state: config.state)
        receiver = config.receiver
        if let loggable = loggable(environ: environ) {
            loggable.debug("[\(id)] INIT")
        }
    }
    
    deinit {
        if let loggable = loggable(environ: environ) {
            loggable.debug("[\(id)] DEINIT")
        }
    }
    
    final public func setUp() {
        let loggable = loggable(environ: environ)
        loggable?.debug("[\(id)] SET UP")
        domain.resetCommandBarrier()
        task = Task {
            let scopes = scopes(Interactor(environ: environ, stateGetter: { [weak self] in await self?.domain.state ?? State() }, commandSource: domain.commandSource, commandDrain: domain.commandDrain, effectDrain: effectGate.asDrain, eventSource: domain.eventSource))
            await activateScopesOnDemand(scopes: scopes, environ: environ, state: domain.state)
            self.domain.signalCommandBarrier()
            do {
                let commandDrain = domain.commandDrain
                let eventDrain = domain.eventDrain
                let receiver = receiver
                while true {
                    try await effectGate.process { [unowned self] (effects: [Effect]) -> [Event] in
                        loggable?.info("[\(id)] Will reduce: \(effects)")
                        let oldState = await self.domain.state
                        self.willReduce(state: oldState, effects: effects)
                        let (newState, events) = effectCombiner(oldState, effects).reduce((oldState, [Event]())) { stateEvents, effect in
                            let (state, events) = reducer(stateEvents.0, effect)
                            return (state, stateEvents.1 + events)
                        }
                        if oldState == newState && events.isEmpty { return [] }
                        self.domain.resetCommandBarrier()
                        await self.domain.setState(state: newState)
                        //loggable?.info("[\(id)] state: \(state)")
                        await self.activateScopesOnDemand(scopes: scopes, environ: self.environ, state: newState)
                        self.domain.signalCommandBarrier()
                        loggable?.info("[\(id)] Did reduce: \(events)")
                        self.didReduce(state: newState, events: events)
                        self.deactivateScopesOnDemand(scopes: scopes, environ: self.environ, state: newState)
                        for event in events {
                            Task {
                                try? await eventDrain.send(event)
                                try? await receiver?(newState, event, commandDrain)
                            }
                        }
                        return events
                    }
                }
            } catch {
                switch error {
                case is CancellationError:
                    loggable?.debug("[\(id)] Effect gate is canceled")
                default:
                    loggable?.error("[\(id)] Effect gate critical error: \(error.localizedDescription)")
                }
            }
            await deactivateScopesOnDemand(scopes: scopes, environ: environ, state: domain.state, force: true)
        }
        onSetUp()
    }
    
    final public func tearDown() {
        loggable(environ: environ)?.debug("[\(id)] TEAR DOWN")
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
    
    private func activateScopesOnDemand(scopes: [Scope<State>], environ: Environ, state: State) async {
        await scopes.forEachAsync { scope in
            await scope.activateOnDemand(environ: environ, loggable: loggable(environ: environ), modelId: id, state: state)
        }
    }
    
    private func deactivateScopesOnDemand(scopes: [Scope<State>], environ: Environ, state: State, force: Bool = false) {
        scopes.forEach { scope in
            scope.deactivateOnDemand(environ: environ, state: state, force: force)
        }
    }

}
