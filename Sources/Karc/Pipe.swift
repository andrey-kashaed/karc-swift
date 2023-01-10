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

enum PipeStatus {
    case start(pipeId: String, time: Int64)
    case restart(pipeId: String, error: Error, time: Int64, executionInterval: Int64)
    case interrupt(pipeId: String, error: Error, time: Int64, executionInterval: Int64)
    case stop(pipeId: String, time: Int64, executionInterval: Int64)
    case finish(pipeId: String, time: Int64, executionInterval: Int64)
    case launch(pipeId: String, time: Int64)
    case success(pipeId: String, time: Int64, iterationInterval: Int64)
    case failure(pipeId: String, error: Error, time: Int64, iterationInterval: Int64)
}

fileprivate struct PipeLog: Loggable {
    
    fileprivate let loggable: Loggable?
    fileprivate let modelId: String
    fileprivate let pipelineId: String
    fileprivate let pipeId: String
    
    func error(_ message: String) {
        loggable?.error("[\(modelId)|\(pipelineId)|\(pipeId)] \(message)")
    }
    func warn(_ message: String) {
        loggable?.warn("[\(modelId)|\(pipelineId)|\(pipeId)] \(message)")
    }
    func info(_ message: String) {
        loggable?.info("[\(modelId)|\(pipelineId)|\(pipeId)] \(message)")
    }
    func debug(_ message: String) {
        loggable?.debug("[\(modelId)|\(pipelineId)|\(pipeId)] \(message)")
    }
    
}

public struct Pipe {
    
    public enum Mode<SI, SO, TI, TO, DI, DO> {
        case simplex(
            instantOutput: SO? = nil,
            intro: ((AnyAsyncSequence<SI>) -> AnyAsyncSequence<TI>)? = nil,
            outro: (AnyAsyncSequence<TO>) -> AnyAsyncSequence<DI> = { (seq: AnyAsyncSequence<TO>) -> AnyAsyncSequence<DI> in
                seq.compactMap { $0 as? DI }.eraseToAnyAsyncSequence()
            }
        )
        case duplex(
            outro: (AnyAsyncSequence<TO>) -> AnyAsyncSequence<DI> = { (seq: AnyAsyncSequence<TO>) -> AnyAsyncSequence<DI> in
                seq.compactMap { $0 as? DI }.eraseToAnyAsyncSequence()
            }
        )
    }
    
    public enum Policy {
        case finite(count: Int), infinite
    }
    
    let id: String
    let runnable: (Loggable?, String, String, @escaping (PipeStatus) -> Void) async -> Void
    
    public init<SI, SO, TI, TO>(
        id: String,
        interruptOnError: Bool = false,
        mode: Mode<SI, SO, TI, TO, Any, Void>,
        source: AnySource<SI, SO>,
        track: @escaping (Loggable) -> IO<TI, TO>
    ) {
        self.init(id: id, interruptOnError: interruptOnError, mode: mode, source: source, drain: nil, track: track)
    }
    
    public init<SI, SO, TI, TO, DI, DO>(
        id: String,
        interruptOnError: Bool = false,
        mode: Mode<SI, SO, TI, TO, DI, DO>,
        source: AnySource<SI, SO>,
        drain: AnyDrain<DI, DO>,
        track: @escaping (Loggable) -> IO<TI, TO>
    ) {
        self.init(id: id, interruptOnError: interruptOnError, mode: mode, source: source, drain: drain as AnyDrain<DI, DO>?, track: track)
    }
    
    private init<SI, SO, TI, TO, DI, DO>(
        id: String,
        interruptOnError: Bool,
        mode: Mode<SI, SO, TI, TO, DI, DO>,
        source: AnySource<SI, SO>,
        drain: AnyDrain<DI, DO>?,
        track: @escaping (Loggable) -> IO<TI, TO>
    ) {
        self.id = id
        self.runnable = { (loggable: Loggable?, modelId: String, pipelineId: String, onStatus: @escaping (PipeStatus) -> Void) in
            let log = PipeLog(loggable: loggable, modelId: modelId, pipelineId: pipelineId, pipeId: id)
            let refinedTrack = Pipe.buildRefinedTrack(
                track: track,
                onStatus: onStatus,
                log: log,
                pipeId: id
            )
            let flow: () -> AnyAsyncSequence<Any> = {
                switch mode {
                case .simplex(let instantOutput, let intro, let outro):
                    let seq: AnyAsyncSequence<TO> = {
                        if let intro = intro {
                            return intro(source.receiver(instantOutput: instantOutput ?? () as! SO)).map({ try await refinedTrack($0) }).eraseToAnyAsyncSequence()
                        } else {
                            switch refinedTrack {
                            case let refinedTrack as IO<SI, TO>:
                                return source.receiver(instantOutput: instantOutput ?? () as! SO).map({ try await refinedTrack($0) }).eraseToAnyAsyncSequence()
                            default:
                                return source.receiver(instantOutput: instantOutput ?? () as! SO).map({ try await refinedTrack($0) }).eraseToAnyAsyncSequence()
                            }
                        }
                    }()
                    if let drain = drain {
                        return drain.sender(
                            provider: {
                                switch (seq) {
                                case let seq as AnyAsyncSequence<DI>:
                                    return seq
                                default:
                                    return outro(seq)
                                }
                            }()
                        ).map { $0 as Any }.eraseToAnyAsyncSequence()
                    } else {
                        return seq.map { $0 as Any }.eraseToAnyAsyncSequence()
                    }
                case .duplex(let outro):
                    let seq: AnyAsyncSequence<TO> = {
                        switch refinedTrack {
                        case let refinedTrack as IO<SI, TO>:
                            return source.processor(operation: { ti in try await refinedTrack(ti) as! SO }).map { $0 as! TO }.eraseToAnyAsyncSequence()
                        default:
                            return source.processor(operation: { ti in try await refinedTrack(ti) as! SO }).map { $0 as! TO }.eraseToAnyAsyncSequence()
                        }
                    }()
                    if let drain = drain {
                        return drain.sender(
                            provider: {
                                switch (seq) {
                                case let seq as AnyAsyncSequence<DI>:
                                    return seq
                                default:
                                    return outro(seq)
                                }
                            }()
                        ).map { $0 as Any }.eraseToAnyAsyncSequence()
                    } else {
                        return seq.map { $0 as Any }.eraseToAnyAsyncSequence()
                    }
                }
            }
            await Pipe.execute(
                pipeId: id,
                onStatus: onStatus,
                flow: flow,
                interruptOnError: interruptOnError
            )
        }
    }
    
    public init(
        id: String,
        interruptOnError: Bool = false,
        policy: Policy,
        track: @escaping (Loggable) -> IO<Void, Void>
    ) {
        self.id = id
        self.runnable = { (loggable: Loggable?, modelId: String, pipelineId: String, onStatus: @escaping (PipeStatus) -> Void) in
            let log = PipeLog(loggable: loggable, modelId: modelId, pipelineId: pipelineId, pipeId: id)
            let refinedTrack = Pipe.buildRefinedTrack(
                track: track,
                onStatus: onStatus,
                log: log,
                pipeId: id
            )
            await Pipe.execute(
                pipeId: id,
                onStatus: onStatus,
                flow: {
                    switch policy {
                    case .finite(let count):
                        return iterate(count: count).map({ try await refinedTrack($0) }).map { $0 as Any }.eraseToAnyAsyncSequence()
                    case .infinite:
                        return iterate().map({ try await refinedTrack($0) }).map { $0 as Any }.eraseToAnyAsyncSequence()
                    }
                },
                interruptOnError: interruptOnError
            )
        }
    }
    
    private static func buildRefinedTrack<I, O>(
        track: @escaping (Loggable) -> IO<I, O>,
        onStatus: @escaping (PipeStatus) -> Void,
        log: PipeLog,
        pipeId: String
    ) -> IO<I, O> {
        return { i in
            let iterationStartTime = Date().millisecondsSince1970
            do {
                onStatus(.launch(
                    pipeId: pipeId,
                    time: iterationStartTime
                ))
                let o = try await track(log)(i)
                let successTime = Date().millisecondsSince1970
                let iterationInterval: Int64 = successTime - iterationStartTime
                onStatus(.success(
                    pipeId: pipeId,
                    time: successTime,
                    iterationInterval: iterationInterval
                ))
                return o
            } catch {
                let failureTime = Date().millisecondsSince1970
                let iterationInterval: Int64 = failureTime - iterationStartTime
                onStatus(.failure(
                    pipeId: pipeId,
                    error: error,
                    time: failureTime,
                    iterationInterval: iterationInterval
                ))
                throw error
            }
        }
    }
    
    private static func execute(
        pipeId: String,
        onStatus: @escaping (PipeStatus) -> Void,
        flow: () -> AnyAsyncSequence<Any>,
        interruptOnError: Bool
    ) async {
        let executionStartTime: Int64 = Date().millisecondsSince1970
        onStatus(.start(pipeId: pipeId, time: executionStartTime))
        var flowError: Error? = nil
        while true {
            do {
                for try await _ in flow() {}
            } catch {
                flowError = error
                if !Task.isCancelled && !interruptOnError {
                    let executionRestartTime = Date().millisecondsSince1970
                    let executionInterval = executionRestartTime - executionStartTime
                    onStatus(
                        .restart(
                            pipeId: pipeId,
                            error: error,
                            time: executionRestartTime,
                            executionInterval: executionInterval
                        )
                    )
                    continue
                }
            }
            break
        }
        let executionStopTime = Date().millisecondsSince1970
        let executionInterval = executionStopTime - executionStartTime
        if Task.isCancelled {
            onStatus(
                .stop(
                    pipeId: pipeId,
                    time: executionStopTime,
                    executionInterval: executionInterval
                )
            )
        } else if let flowError = flowError {
            onStatus(
                .interrupt(
                    pipeId: pipeId,
                    error: flowError,
                    time: executionStopTime,
                    executionInterval: executionInterval
                )
            )
        } else {
            onStatus(
                .finish(
                    pipeId: pipeId,
                    time: executionStopTime,
                    executionInterval: executionInterval
                )
            )
        }
    }
    
    func run(loggable: Loggable?, modelId: String, pipelineId: String, onStatus: @escaping (PipeStatus) -> Void) async {
        await runnable(loggable, modelId, pipelineId, onStatus)
    }
    
}

@resultBuilder
public struct PipeBuilder {
    
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
