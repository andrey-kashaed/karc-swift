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

public final class Pipeline: Scope, @unchecked Sendable {
    
    public let uid: AnyUid
    private let beginPipeFactory: @Sendable () -> Pipe?
    private let endPipeFactory: @Sendable () -> Pipe?
    private let pipesFactory: @Sendable () -> [Pipe]
    @AtomicReference(nil as Task<Void, Never>?) private var task
    @AtomicReference(false) private var terminating
    @AtomicReference(false) private var relaunching
    
    public init<Id>(
        tag: String = #function,
        id: Id = DefaultId.shared,
        begin: PipeTrack<Void, Void>? = nil,
        end: PipeTrack<Void, Void>? = nil,
        @PipesBuilder pipes: @Sendable @escaping () -> [Pipe]
    ) where Id: Equatable & Hashable & Sendable {
        self.uid = Uid(tag: tag.components(separatedBy: "(").getOrNil(0) ?? tag, id: id).asAny
        self.beginPipeFactory = {
            guard let track = begin else { return nil }
            return Pipe(id: "begin", policy: .finite(count: 1), track: track)
        }
        self.endPipeFactory = {
            guard let track = end else { return nil }
            return Pipe(id: "end", policy: .finite(count: 1), track: track)
        }
        self.pipesFactory = pipes
    }
    
    public func activate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await launch(logger: logger, modelUid: modelUid)
    }
    
    public func deactivate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await terminate()
    }
    
    private func launch(logger: Logger, modelUid: AnyUid) async {
        let beginPipe = beginPipeFactory()
        let endPipe = endPipeFactory()
        let pipes = pipesFactory()
        let barrier = Barrier(requiredParties: pipes.count + 1)
        let contexts: [String: PipeContext] = (pipes + beginPipe + endPipe).reduce(into: [:]) { (contexts: inout [String: PipeContext], pipe: Pipe) in
            contexts[pipe.id] = PipeContext(
                modelUid: modelUid,
                pipelineUid: self.uid,
                pipeId: pipe.id,
                barrier: (pipe.id != beginPipe?.id && pipe.id != endPipe?.id) ? barrier : nil,
                logger: logger,
                pipeline: self
            )
        }
        @Sendable func getContext(pipeId: String) -> PipeContext {
            contexts[pipeId]!
        }
        await task =^ Task<Void, Never>.detached { [weak self] in
            if let beginPipe {
                let context = getContext(pipeId: beginPipe.id)
                await beginPipe.run(context)
            }
            await withTaskGroup(of: Void.self) { taskGroup in
                pipes.forEach { pipe in
                    let _ = taskGroup.addTaskUnlessCancelled {
                        let context = getContext(pipeId: pipe.id)
                        await pipe.run(context)
                    }
                }
                await taskGroup.waitForAll()
            }
            if let endPipe {
                let context = getContext(pipeId: endPipe.id)
                await endPipe.run(context)
            }
            guard let self else { return }
            if await self.relaunching^ &&^ (await !self.terminating^) {
                await self.relaunching =^ false
                await self.launch(logger: logger, modelUid: modelUid)
            }
        }
        try? await barrier.await()
    }
    
    internal func relaunch() async {
        await relaunching =^ true
        await task.atomic {
            $0?.cancel()
            $0 = nil
        }
    }
    
    private func terminate() async {
        await terminating =^ true
        await task.atomic {
            $0?.cancel()
            $0 = nil
        }
    }
 
}
