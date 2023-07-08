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

public enum PipeState: Sendable {
    case opened(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration, initial: Bool)
    case started(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration)
    case stopped(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration, trackDuration: ContinuousClock.Duration, error: Error?)
    case finished(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration, trackDuration: ContinuousClock.Duration)
    case interrupted(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration, error: Error)
    case broken(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration, error: Error)
    case closed(time: ContinuousClock.Instant, flowDuration: ContinuousClock.Duration, canceled: Bool)
}

public final class PipeContext: @unchecked Sendable {
    
    public let modelUid: AnyUid
    public let pipelineUid: AnyUid
    public let pipeId: String
    @AtomicReference(PipeState.closed(time: ContinuousClock.now, flowDuration: ContinuousClock.Duration.zero, canceled: false)) public var internalPipeState
    private let barrier: Barrier?
    @AtomicReference(true) private var needAwaitBarrier
    private let logger: Logger
    private weak var pipeline: Pipeline?
    @AtomicReference(ContinuousClock.Instant.now) fileprivate var internalFlowInitialTime
    
    init(modelUid: AnyUid, pipelineUid: AnyUid, pipeId: String, barrier: Barrier?, logger: Logger, pipeline: Pipeline) {
        self.modelUid = modelUid
        self.pipelineUid = pipelineUid
        self.pipeId = pipeId
        self.barrier = barrier
        self.logger = logger
        self.pipeline = pipeline
    }
    
    fileprivate func awaitBarrierIfNeeded() async {
        if await needAwaitBarrier.atomic({ needAwaitBarrier in defer { if needAwaitBarrier { needAwaitBarrier = false } }; return needAwaitBarrier; }) {
            try? await barrier?.await()
        }
    }
    
    public var pipeState: PipeState {
        get async {
            await internalPipeState^
        }
    }
    
    fileprivate func setPipeState(_ pipeState: PipeState) async {
        await internalPipeState =^ pipeState
        switch pipeState {
        case .opened(_, let flowDuration, let initial):
            logInfo("OPENED flowDuration: \(flowDuration), initial: \(initial)")
        case .started(_, let flowDuration):
            logInfo("STARTED flowDuration: \(flowDuration)")
        case .stopped(_, let flowDuration, let trackDuration, let error):
            logInfo("STOPPED flowDuration: \(flowDuration), trackDuration: \(trackDuration), error: \(String(describing: error))")
        case .finished(_, let flowDuration, let trackDuration):
            logInfo("FINISHED flowDuration: \(flowDuration), trackDuration: \(trackDuration)")
        case .interrupted(_, let flowDuration, let error):
            logWarning("INTERRUPTED flowDuration: \(flowDuration), error: \(error)")
        case .broken(_, let flowDuration, let error):
            logError("BROKEN flowDuration: \(flowDuration), error: \(error)")
            await pipeline?.relaunch()
        case .closed(_, let flowDuration, let canceled):
            logInfo("CLOSED flowDuration: \(flowDuration), canceled: \(canceled)")
        }
    }
    
    public var flowInitialTime: ContinuousClock.Instant {
        get async {
            await internalFlowInitialTime^
        }
    }
    
    fileprivate func setFlowInitialTime(_ flowInitialTime: ContinuousClock.Instant) async {
        await internalFlowInitialTime =^ flowInitialTime
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
            intro: ((AsyncThrowingStream<SI, Error>) -> AsyncThrowingStream<TI, Error>)? = nil,
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
        case finite(count: Int), infinite
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
                    let seq: AsyncThrowingStream<TO, Error> = {
                        if let intro = intro {
                            return intro(source.receiver(instantOutput: instantOutput ?? () as! SO)).map({ try await refinedTrack($0, context) })*!
                        } else {
                            switch refinedTrack {
                            case let refinedTrack as PipeTrack<SI, TO>:
                                return source.receiver(instantOutput: instantOutput ?? () as! SO).map({ try await refinedTrack($0, context) })*!
                            default:
                                return source.receiver(instantOutput: instantOutput ?? () as! SO).map({ try await refinedTrack($0, context) })*!
                            }
                        }
                    }()
                    if let drain = drain {
                        return drain.sender(
                            provider: {
                                switch (seq) {
                                case let seq as AsyncThrowingStream<DI, Error>:
                                    return seq
                                default:
                                    return outro(seq)
                                }
                            }()
                        ).map { $0 as Any }*!
                    } else {
                        return seq.map { $0 as Any }*!
                    }
                case .duplex(let outro):
                    let seq: AsyncThrowingStream<TO, Error> = {
                        switch refinedTrack {
                        case let refinedTrack as PipeTrack<SI, TO>:
                            return source.processor(operation: { ti in try await refinedTrack(ti, context) as! SO }).map { $0 as! TO }*!
                        default:
                            return source.processor(operation: { ti in try await refinedTrack(ti, context) as! SO }).map { $0 as! TO }*!
                        }
                    }()
                    if let drain = drain {
                        return drain.sender(
                            provider: {
                                switch (seq) {
                                case let seq as AsyncThrowingStream<DI, Error>:
                                    return seq
                                default:
                                    return outro(seq)
                                }
                            }()
                        ).map { $0 as Any }*!
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
                case .finite(let count):
                    return iterate(count: count).map({ try await refinedTrack($0, context) })*!
                case .infinite:
                    return iterateInfinitely().map({ try await refinedTrack($0, context) })*!
                }
            }
            await Pipe.execute(
                context: context,
                flowFactory: flowFactory,
                recoverFromError: recoverFromError
            )
        }
    }
    
    private static func buildRefinedTrack<I, O>(
        track: @escaping PipeTrack<I, O>
    ) -> PipeTrack<I, O> {
        return { i, context in
            let trackInitialTime = ContinuousClock.now
            do {
                await context.setPipeState(.started(time: trackInitialTime, flowDuration: trackInitialTime - context.flowInitialTime))
                let o = try await track(i, context)
                let currentTime = ContinuousClock.now
                await context.setPipeState(.finished(
                    time: currentTime,
                    flowDuration: currentTime - context.flowInitialTime,
                    trackDuration: currentTime - trackInitialTime
                ))
                return o
            } catch {
                let currentTime = ContinuousClock.now
                await context.setPipeState(.stopped(
                    time: currentTime,
                    flowDuration: currentTime - context.flowInitialTime,
                    trackDuration: currentTime - trackInitialTime,
                    error: error is CancellationError ? nil : error
                ))
                throw error
            }
        }
    }
    
    private static func execute(
        context: PipeContext,
        flowFactory: () -> AsyncThrowingStream<Any, Error>,
        recoverFromError: Bool
    ) async {
        while true {
            var flowError: Error? = nil
            let flow = flowFactory()*~
            await context.awaitBarrierIfNeeded()
            let flowInitialTime = ContinuousClock.now
            await context.setFlowInitialTime(flowInitialTime)
            do {
                await context.setPipeState(.opened(time: flowInitialTime, flowDuration: ContinuousClock.Duration.zero, initial: true))
                for try await _ in flow {
                    if !flow.terminated {
                        let currentTime = ContinuousClock.now
                        await context.setPipeState(.opened(time: currentTime, flowDuration: currentTime - flowInitialTime, initial: false))
                    }
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) && recoverFromError {
                    let currentTime = ContinuousClock.now
                    await context.setPipeState(
                        .interrupted(
                            time: currentTime,
                            flowDuration: currentTime - flowInitialTime,
                            error: error
                        )
                    )
                    continue
                }
                flowError = error
            }
            let currentTime = ContinuousClock.now
            if Task.isCancelled || flowError is CancellationError {
                await context.setPipeState(
                    .closed(
                        time: currentTime,
                        flowDuration: currentTime - flowInitialTime,
                        canceled: true
                    )
                )
            } else if let flowError = flowError {
                await context.setPipeState(
                    .broken(
                        time: currentTime,
                        flowDuration: currentTime - flowInitialTime,
                        error: flowError
                    )
                )
            } else {
                await context.setPipeState(
                    .closed(
                        time: currentTime,
                        flowDuration: currentTime - flowInitialTime,
                        canceled: false
                    )
                )
            }
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
