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

public enum PipeStatus: Sendable {
    case started
    case stopped(error: Error?)
    case flushed
    case interrupted(error: Error)
    case broken(error: Error)
    case finished(canceled: Bool)
}

public enum PipeState: String, Sendable {
    case scheduled = "SCHEDULED", open = "OPEN", closed = "CLOSED"
}

public struct ConcurrentAttemptToStartPipeTrack: LocalizedError {
    public var errorDescription: String? { "Concurrent attempt to start track" }
}

public struct ConcurrentAttemptToStopPipeTrack: LocalizedError {
    public var errorDescription: String? { "Concurrent attempt to stop track" }
}

public final actor PipeContext {
    
    public let modelUid: AnyUid
    public let pipelineUid: AnyUid
    public let pipeId: String
    private var internalPipeState = PipeState.closed
    private let barrier: Barrier?
    private var needAwaitBarrier = true
    private let logger: Logger
    private weak var pipeline: Pipeline?
    private var trackStarted: ContinuousClock.Instant? = nil
    private var stateModified = ContinuousClock.Instant.now
    
    internal init(modelUid: AnyUid, pipelineUid: AnyUid, pipeId: String, barrier: Barrier?, logger: Logger, pipeline: Pipeline) {
        self.modelUid = modelUid
        self.pipelineUid = pipelineUid
        self.pipeId = pipeId
        self.barrier = barrier
        self.logger = logger
        self.pipeline = pipeline
    }
    
    fileprivate func awaitBarrierIfNeeded() async {
        if needAwaitBarrier {
            needAwaitBarrier = false
            try? await barrier?.await()
        }
    }
    
    public var pipeState: PipeState {
        get {
            internalPipeState
        }
    }
    
    fileprivate func setPipeState(_ pipeState: PipeState) {
        let now = ContinuousClock.Instant.now
        logTrace("\(pipeState.rawValue) <= \(internalPipeState.rawValue)(stateTime: \(now - stateModified))")
        internalPipeState = pipeState
        stateModified = now
    }
    
    @discardableResult
    fileprivate func applyPipeStatus(_ pipeStatus: PipeStatus) async -> Bool {
        switch pipeStatus {
        case .started:
            guard trackStarted == nil else { logError("Concurrent attempt to start track is forbidden"); return false }
            let now = ContinuousClock.Instant.now
            trackStarted = now
            let stateTime = now - stateModified
            logTrace("STARTED stateTime: \(stateTime)")
        case .stopped(let error):
            guard let trackStarted = trackStarted else { logError("Concurrent attempt to stop track is forbidden"); return false }
            self.trackStarted = nil
            let now = ContinuousClock.Instant.now
            let stateTime = now - stateModified
            let trackTime = now - trackStarted
            logTrace("STOPPED stateTime: \(stateTime), trackTime: \(trackTime), error: \(String(describing: error))")
        case .flushed:
            let stateTime = ContinuousClock.Instant.now - stateModified
            logTrace("FLUSHED stateTime: \(stateTime)")
        case .interrupted(let error):
            let stateTime = ContinuousClock.Instant.now - stateModified
            logWarning("INTERRUPTED stateTime: \(stateTime), error: \(error)")
        case .broken(let error):
            let stateTime = ContinuousClock.Instant.now - stateModified
            logError("BROKEN stateTime: \(stateTime), error: \(error)")
            await pipeline?.relaunch()
        case .finished(let canceled):
            let stateTime = ContinuousClock.Instant.now - stateModified
            logTrace("FINISHED stateTime: \(stateTime), canceled: \(canceled)")
        }
        return true
    }
    
    nonisolated public func logError(priority: Int = LogPriority.highest, _ message: String) {
        logger.error(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logWarning(priority: Int = LogPriority.high, _ message: String) {
        logger.warning(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logInfo(priority: Int = LogPriority.medium, _ message: String) {
        logger.info(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logDebug(priority: Int = LogPriority.low, _ message: String) {
        logger.debug(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logTrace(priority: Int = LogPriority.lowest, _ message: String) {
        logger.trace(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
}

public typealias PipeTrack<I, O> = (I, PipeContext) async throws -> O

public func % <I, O>(
    f: @escaping PipeTrack<I, O>,
    c: @escaping (Error, I, PipeContext) async -> Void
) -> PipeTrack<I, O> {
    { i, context in
        do {
            return try await f(i, context)
        } catch {
            await c(error, i, context)
            throw error
        }
    }
}

public struct Pipe: Sendable {
    
    public enum Mode<SI, SO, TI, TO, DI, DO> {
        case simplex(
            instantOutput: SO? = nil,
            intro: ((AsyncThrowingStream<TI, Error>) -> AsyncThrowingStream<TI, Error>)? = nil,
            outro: (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> = { (seq: AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> in
                seq.compactMap { $0 as? DI }*!
            }
        )
        case duplex(
            outro: (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> = { (seq: AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> in
                seq.compactMap { $0 as? DI }*!
            }
        )
    }
    
    public enum Policy {
        case finite(delay: Duration? = nil, count: Int), infinite(delay: Duration? = nil)
    }
    
    let id: String
    let runnable: @Sendable (PipeContext) async -> Void
    
    public init<SI, SO, TI, TO>(
        id: String,
        recoverFromError: Bool = true,
        mode: Mode<SI, SO, TI, TO, Any, Void>,
        source: any Source<SI, SO>,
        track: @escaping PipeTrack<TI, TO>
    ) {
        self.init(id: id, recoverFromError: recoverFromError, mode: mode, source: source, drain: nil, track: track)
    }
    
    public init<SI, SO, TI, TO, DI, DO>(
        id: String,
        recoverFromError: Bool = true,
        mode: Mode<SI, SO, TI, TO, DI, DO>,
        source: any Source<SI, SO>,
        drain: any Drain<DI, DO>,
        track: @escaping PipeTrack<TI, TO>
    ) {
        self.init(id: id, recoverFromError: recoverFromError, mode: mode, source: source, drain: drain as (any Drain<DI, DO>)?, track: track)
    }
    
    private init<SI, SO, TI, TO, DI, DO>(
        id: String,
        recoverFromError: Bool,
        mode: Mode<SI, SO, TI, TO, DI, DO>,
        source: any Source<SI, SO>,
        drain: (any Drain<DI, DO>)?,
        track: @escaping PipeTrack<TI, TO>
    ) {
        self.id = id
        self.runnable = { (context: PipeContext) in
            let refinedTrack = Pipe.buildRefinedTrack(track: track)
            let flowFactory: () -> AsyncThrowingStream<Any, Error> = {
                switch mode {
                case .simplex(let instantOutput, let intro, let outro):
                    let seq1: AsyncThrowingStream<TI, Error> = { () -> AsyncThrowingStream<TI, Error> in
                        switch refinedTrack {
                        case is PipeTrack<SI, TO>:
                            return (source.receiver(instantOutput: instantOutput ?? () as! SO) as AsyncThrowingStream<SI, Error>) as! AsyncThrowingStream<TI, Error>
                        default:
                            return source.receiver(instantOutput: instantOutput ?? () as! SO)
                        }
                    }()
                    let seq2: AsyncThrowingStream<TI, Error> = {
                        if let intro {
                            return intro(seq1)
                        } else {
                            return seq1
                        }
                    }()
                    let seq3: AsyncThrowingStream<TO, Error> = seq2.map({ try await refinedTrack($0, context) })*!
                    if let drain {
                        return drain.sender(provider: outro(seq3)).map { $0 as Any }*!
                    } else {
                        return seq3.map { $0 as Any }*!
                    }
                case .duplex(let outro):
                    let seq: AsyncThrowingStream<TO, Error> = {
                        switch refinedTrack {
                        case let refinedTrack as PipeTrack<SI, TO>:
                            return source.processor(operation: { ti in try await refinedTrack(ti, context) as! SO}).map { $0 as! TO }*!
                        default:
                            return source.processor(operation: { ti in try await refinedTrack(ti, context) as! SO}).map { $0 as! TO }*!
                        }
                    }()
                    if let drain {
                        return drain.sender(provider: outro(seq)).map { $0 as Any }*!
                    } else {
                        return seq.map { $0 as Any }*!
                    }
                }
            }
            await Pipe.execute(
                context: context,
                flowFactory: flowFactory,
                recoverFromError: recoverFromError
            )
        }
    }
    
    public init(
        id: String,
        recoverFromError: Bool = true,
        policy: Policy,
        track: @escaping PipeTrack<Void, Void>
    ) {
        self.id = id
        self.runnable = { (context: PipeContext) in
            let refinedTrack = Pipe.buildRefinedTrack(track: track)
            let flowFactory: () -> AsyncThrowingStream<Any, Error> = {
                switch policy {
                case .finite(let delay, let count):
                    return iterate(delay: delay, count: count).map({ try await refinedTrack($0, context) })*!
                case .infinite(let delay):
                    return iterateInfinitely(delay: delay).map({ try await refinedTrack($0, context) })*!
                }
            }
            await Pipe.execute(
                context: context,
                flowFactory: flowFactory,
                recoverFromError: recoverFromError
            )
        }
    }
    
    private static func buildRefinedTrack<I, O>(track: @escaping PipeTrack<I, O>) -> PipeTrack<I, O> {
        return { i, context in
            let startedSuccessfully = await context.applyPipeStatus(.started)
            if !startedSuccessfully {
                throw ConcurrentAttemptToStartPipeTrack()
            }
            let trackResult: Result<O, Error> = await {
                do {
                    return Result.success(try await track(i, context))
                } catch {
                    return Result.failure(error)
                }
            }()
            let trackError: Error? = {
                switch trackResult {
                case .success(_):
                    return nil
                case .failure(let error):
                    return error
                }
            }()
            let stoppedSuccessfully = await context.applyPipeStatus(.stopped(error: trackError))
            if !stoppedSuccessfully {
                throw ConcurrentAttemptToStopPipeTrack()
            }
            switch trackResult {
            case .success(let o):
                return o
            case .failure(let error):
                throw error
            }
        }
    }
    
    private static func execute(context: PipeContext, flowFactory: () -> AsyncThrowingStream<Any, Error>, recoverFromError: Bool) async {
        while true {
            await context.setPipeState(.scheduled)
            var flowError: Error? = nil
            let flow = flowFactory()*~
            await context.awaitBarrierIfNeeded()
            await context.setPipeState(.open)
            do {
                for try await _ in flow {
                    await context.applyPipeStatus(.flushed)
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) && recoverFromError {
                    await context.applyPipeStatus(.interrupted(error: error))
                    continue
                }
                flowError = error
            }
            if Task.isCancelled || flowError is CancellationError {
                await context.applyPipeStatus(.finished(canceled: true))
            } else if let flowError {
                await context.applyPipeStatus(.broken(error: flowError))
            } else {
                await context.applyPipeStatus(.finished(canceled: false))
            }
            await context.setPipeState(.closed)
            break
        }
    }
    
    func run(_ context: PipeContext) async {
        await runnable(context)
    }
    
}

@resultBuilder
public struct PipesBuilder: Sendable {
    
    public static func buildBlock() -> [Pipe] {
        []
    }
    
    public static func buildBlock(_ pipes: [Pipe]...) -> [Pipe] {
        pipes.flatMap { $0 }
    }
    
    public static func buildArray(_ pipes: [[Pipe]]) -> [Pipe] {
        pipes.flatMap { $0 }
    }
    
    public static func buildExpression(_ pipe: Pipe) -> [Pipe] {
        [pipe]
    }
    
}
