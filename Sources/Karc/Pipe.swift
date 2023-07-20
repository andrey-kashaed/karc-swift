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
    
    fileprivate func setPipeState(_ pipeState: PipeState) async {
        let now = ContinuousClock.Instant.now
        await logTrace("\(pipeState.rawValue) <= \(internalPipeState.rawValue)(stateTime: \(now - stateModified))")
        internalPipeState = pipeState
        stateModified = now
    }
    
    @discardableResult
    fileprivate func applyPipeStatus(_ pipeStatus: PipeStatus) async -> Bool {
        switch pipeStatus {
        case .started:
            guard trackStarted == nil else { await logError("Concurrent attempt to start track is forbidden"); return false }
            let now = ContinuousClock.Instant.now
            trackStarted = now
            let stateTime = now - stateModified
            await logTrace("STARTED stateTime: \(stateTime)")
        case .stopped(let error):
            guard let trackStarted = trackStarted else { await logError("Concurrent attempt to stop track is forbidden"); return false }
            self.trackStarted = nil
            let now = ContinuousClock.Instant.now
            let stateTime = now - stateModified
            let trackTime = now - trackStarted
            await logTrace("STOPPED stateTime: \(stateTime), trackTime: \(trackTime), error: \(String(describing: error))")
        case .flushed:
            let stateTime = ContinuousClock.Instant.now - stateModified
            await logTrace("FLUSHED stateTime: \(stateTime)")
        case .interrupted(let error):
            let stateTime = ContinuousClock.Instant.now - stateModified
            await logWarning("INTERRUPTED stateTime: \(stateTime), error: \(error)")
        case .broken(let error):
            let stateTime = ContinuousClock.Instant.now - stateModified
            await logError("BROKEN stateTime: \(stateTime), error: \(error)")
            await pipeline?.relaunch()
        case .finished(let canceled):
            let stateTime = ContinuousClock.Instant.now - stateModified
            await logTrace("FINISHED stateTime: \(stateTime), canceled: \(canceled)")
        }
        return true
    }
    
    nonisolated public func logError(priority: Int = LogPriority.highest, _ message: String) async {
        await logger.error(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logWarning(priority: Int = LogPriority.high, _ message: String) async {
        await logger.warning(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logInfo(priority: Int = LogPriority.medium, _ message: String) async {
        await logger.info(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logDebug(priority: Int = LogPriority.low, _ message: String) async {
        await logger.debug(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
    }
    
    nonisolated public func logTrace(priority: Int = LogPriority.lowest, _ message: String) async {
        await logger.trace(priority: priority, "[\(modelUid)|\(pipelineUid):\(pipeId)] \(message)")
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
    
    private enum Mode<SI, SO, II, TI, TO, DI, DO> {
        case simplex(
            source: any Source<SI, SO>,
            drain: (any Drain<DI, DO>)?,
            instantOutput: SO,
            intro: (AsyncThrowingStream<II, Error>) -> AsyncThrowingStream<TI, Error>,
            outro: (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error>
        )
        case duplex(
            source: any Source<SI, SO>,
            drain: (any Drain<DI, DO>)?,
            outro: (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error>
        )
        case finite(delay: Duration?, count: Int)
        case infinite(delay: Duration?)
    }
    
    let id: String
    let runnable: @Sendable (PipeContext) async -> Void
    
    public static func simplex<SI, SO, II, TI, TO, DI, DO>(
        id: String,
        recoverFromError: Bool = true,
        source: any Source<SI, SO>,
        drain: any Drain<DI, DO>,
        instantOutput: SO,
        intro: @escaping (AsyncThrowingStream<II, Error>) -> AsyncThrowingStream<TI, Error>,
        outro: @escaping (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> = { (seq: AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> in
            switch seq {
            case let seq as AsyncThrowingStream<DI, Error>:
                return seq
            default:
                return seq.compactMap { $0 as? DI }*!
            }
        },
        track: @escaping PipeTrack<TI, TO>
    ) -> Pipe {
        let mode: Mode<SI, SO, II, TI, TO, DI, DO> = .simplex(
            source: source,
            drain: drain,
            instantOutput: instantOutput,
            intro: intro,
            outro: outro
        )
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func simplex<SI, SO, II, TI, TO>(
        id: String,
        recoverFromError: Bool = true,
        source: any Source<SI, SO>,
        instantOutput: SO,
        intro: @escaping (AsyncThrowingStream<II, Error>) -> AsyncThrowingStream<TI, Error>,
        track: @escaping PipeTrack<TI, TO>
    ) -> Pipe {
        let mode: Mode<SI, SO, II, TI, TO, Never, Never> = .simplex(
            source: source,
            drain: nil,
            instantOutput: instantOutput,
            intro: intro,
            outro: { _ in fatalError() }
        )
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func simplex<SI, SO, TI, TO, DI, DO>(
        id: String,
        recoverFromError: Bool = true,
        source: any Source<SI, SO>,
        drain: any Drain<DI, DO>,
        instantOutput: SO,
        outro: @escaping (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> = { (seq: AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> in
            switch seq {
            case let seq as AsyncThrowingStream<DI, Error>:
                return seq
            default:
                return seq.compactMap { $0 as? DI }*!
            }
        },
        track: @escaping PipeTrack<TI, TO>
    ) -> Pipe {
        let mode: Mode<SI, SO, TI, TI, TO, DI, DO> = .simplex(
            source: source,
            drain: drain,
            instantOutput: instantOutput,
            intro: { $0 },
            outro: outro
        )
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func simplex<SI, SO, TI, TO>(
        id: String,
        recoverFromError: Bool = true,
        source: any Source<SI, SO>,
        instantOutput: SO,
        track: @escaping PipeTrack<TI, TO>
    ) -> Pipe {
        let mode: Mode<SI, SO, TI, TI, TO, Never, Never> = .simplex(
            source: source,
            drain: nil,
            instantOutput: instantOutput,
            intro: { $0 },
            outro: { _ in fatalError() }
        )
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func duplex<SI, SO, TI, TO, DI, DO>(
        id: String,
        recoverFromError: Bool = true,
        source: any Source<SI, SO>,
        drain: any Drain<DI, DO>,
        outro: @escaping (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> = { (seq: AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error> in
            switch seq {
            case let seq as AsyncThrowingStream<DI, Error>:
                return seq
            default:
                return seq.compactMap { $0 as? DI }*!
            }
        },
        track: @escaping PipeTrack<TI, TO>
    ) -> Pipe {
        let mode: Mode<SI, SO, TI, TI, TO, DI, DO> = .duplex(
            source: source,
            drain: drain,
            outro: outro
        )
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func duplex<SI, SO, TI, TO>(
        id: String,
        recoverFromError: Bool = true,
        source: any Source<SI, SO>,
        track: @escaping PipeTrack<TI, TO>
    ) -> Pipe {
        let mode: Mode<SI, SO, TI, TI, TO, Never, Never> = .duplex(
            source: source,
            drain: nil,
            outro: { _ in fatalError() }
        )
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func finite(
        id: String,
        recoverFromError: Bool = true,
        delay: Duration? = nil,
        count: Int,
        track: @escaping PipeTrack<Void, Void>
    ) -> Pipe {
        let mode: Mode<Never, Never, Never, Void, Void, Never, Never> = .finite(delay: delay, count: count)
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    public static func infinite(
        id: String,
        recoverFromError: Bool = true,
        delay: Duration? = nil,
        track: @escaping PipeTrack<Void, Void>
    ) -> Pipe {
        let mode: Mode<Never, Never, Never, Void, Void, Never, Never> = .infinite(delay: delay)
        return Pipe(id: id, recoverFromError: recoverFromError, mode: mode, track: track)
    }
    
    private init<SI, SO, II, TI, TO, DI, DO>(
        id: String,
        recoverFromError: Bool,
        mode: Mode<SI, SO, II, TI, TO, DI, DO>,
        track: @escaping PipeTrack<TI, TO>
    ) {
        self.id = id
        self.runnable = { (context: PipeContext) async -> Void in
            let refinedTrack = Pipe.buildRefinedTrack(track: track)
            let flowFactory: () -> AsyncThrowingStream<Any, Error> = { () -> AsyncThrowingStream<Any, Error> in
                switch mode {
                case .simplex(let source, let drain, let instantOutput, let intro, let outro):
                    let seq: AsyncThrowingStream<TO, Error> = { () -> AsyncThrowingStream<TI, Error> in
                        switch intro {
                        case let intro as (AsyncThrowingStream<SI, Error>) -> AsyncThrowingStream<TI, Error>:
                            return intro(source.receiver(instantOutput: instantOutput))
                        default:
                            return intro(source.receiver(instantOutput: instantOutput))
                        }
                    }().map({ try await refinedTrack($0, context) })*!
                    if let drain {
                        return drain.sender(provider: outro(seq)).map { $0 as Any }*!
                    } else {
                        return seq.map { $0 as Any }*!
                    }
                case .duplex(let source, let drain, let outro):
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
                case .finite(let delay, let count):
                    return iterate(delay: delay, count: count).map({ try await refinedTrack($0 as! TI, context) })*!
                case .infinite(let delay):
                    return iterateInfinitely(delay: delay).map({ try await refinedTrack($0 as! TI, context) })*!
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
