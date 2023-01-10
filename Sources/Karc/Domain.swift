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

open class Domain<State: Equatable & Initable, Command, Event> {
    
    private actor StateGuardian {
        var state: State
        init(state: State) {
            self.state = state
        }
        func set(state: State) {
            self.state = state
        }
    }
   
    private let stateGuardian: StateGuardian
    private let commandGate = Gate<Command, Any>(mode: Gate.Mode.transient(), scheme: .anycast)
    private let eventGate = Gate<Event, Void>(mode: Gate.Mode.retainable(), scheme: .broadcast())
    
    private let commandBarrier: Barrier = Barrier(mode: .manual)
    private let commandBarrierLock = NSRecursiveLock()
    
    public required init(state: State) {
        stateGuardian = StateGuardian(state: state)
    }
    
    open func observe(state: State) {}
    
    public var state: State {
        get async {
            await stateGuardian.state
        }
    }
    
    @discardableResult
    public final func send(_ command: Command) async throws -> Any {
        try? await awaitCommandBarrier()
        return try await commandGate.send(command)
    }
    
    public func receiver() -> AnyAsyncSequence<Event> {
        eventGate.receiver()
    }
    
    public func receiver<SubEvent>() -> AnyAsyncSequence<SubEvent> {
        eventGate.receiver()
    }
    
    internal func setState(state: State) async {
        await stateGuardian.set(state: state)
        observe(state: state)
    }
    
    internal var commandSource: AnySource<Command, Any> {
        commandGate.asSource
    }
    
    internal var commandDrain: AnyDrain<Command, Any> {
        commandGate.asDrain
    }
    
    internal var eventSource: AnySource<Event, Void> {
        eventGate.asSource
    }
    
    internal var eventDrain: AnyDrain<Event, Void> {
        eventGate.asDrain
    }
    
    internal func seal() {
        commandGate.seal()
        eventGate.seal()
    }
    
    internal func resetCommandBarrier() {
        commandBarrierLock.synchronized {
            commandBarrier.reset()
        }
    }

    internal func signalCommandBarrier() {
        commandBarrierLock.synchronized {
            commandBarrier.signal()
        }
    }

    private func awaitCommandBarrier() async throws {
        try await commandBarrierLock.synchronized { commandBarrier }.await()
    }

}

public extension Domain {
    
    @discardableResult
    final func sendDetached(_ command: Command) -> Task<Any?, Never> {
        Task.detached { [weak self] in
            try? await self?.send(command)
        }
    }
    
}
