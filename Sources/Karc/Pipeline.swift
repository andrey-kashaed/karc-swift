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

public class Pipeline {
    
    public let id: String
    private let beginPipeProvider: () -> Pipe?
    private let endPipeProvider: () -> Pipe?
    private let pipesProvider: () -> [Pipe]
    private var task: Task<Void, Never>?
    
    @Atomic private var stopping = false
    @Atomic private var restarting = false
    
    public init(
        id: String = #function,
        begin: ((Loggable) -> IO<Void, Void>)? = nil,
        end: ((Loggable) -> IO<Void, Void>)? = nil,
        @PipeBuilder pipesBuilder: @escaping () -> [Pipe]
    ) {
        self.id = id.components(separatedBy: "(").getOrNil(0) ?? id
        self.beginPipeProvider = {
            guard let track = begin else { return nil }
            return Pipe(id: "begin", policy: .finite(count: 1), track: track)
        }
        self.endPipeProvider = {
            guard let track = end else { return nil }
            return Pipe(id: "end", policy: .finite(count: 1), track: track)
        }
        self.pipesProvider = pipesBuilder
    }
    
    func start(loggable: Loggable?, modelId: String, onStatus: @escaping (PipeStatus) -> Void) {
        let beginPipe = beginPipeProvider()
        let endPipe = endPipeProvider()
        let pipes = pipesProvider()
        task = Task<Void, Never> {
            if let beginPipe = beginPipe {
                await beginPipe.run(loggable: loggable, modelId: modelId, pipelineId: id, onStatus: onStatus)
            }
            await withTaskGroup(of: Void.self) { taskGroup in
                pipes.forEach { pipe in
                    let _ = taskGroup.addTaskUnlessCancelled {
                        await pipe.run(loggable: loggable, modelId: modelId, pipelineId: self.id, onStatus: onStatus)
                    }
                }
                await taskGroup.waitForAll()
            }
            if let endPipe = endPipe {
                await endPipe.run(loggable: loggable, modelId: modelId, pipelineId: id, onStatus: onStatus)
            }
            if restarting && !stopping {
                restarting = false
                start(loggable: loggable, modelId: modelId, onStatus: onStatus)
            }
        }
    }
    
    func stop() {
        stopping = true
        task?.cancel()
        task = nil
    }
    
    func restart() {
        restarting = true
        task?.cancel()
        task = nil
    }
 
}
