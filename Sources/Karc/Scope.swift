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

public class Scope<State, Command, Effect, Event> {
    
    let spec: TSpec<State>
    let onEnter: (Environ, State) -> Void
    let onExit: (Environ, State) -> Void
    let submodelsFactory: () -> [Submodel]
    let pipelinesFactory: (Interactor<State, Command, Effect, Event>) -> [Pipeline]
    
    private(set) var isActive = false
    private var submodels: [Submodel] = []
    private var pipelines: [Pipeline] = []
    
    public init(
        spec: TSpec<State>,
        onEnter: @escaping (Environ, State) -> Void = { _, _ in },
        onExit: @escaping (Environ, State) -> Void = { _, _ in },
        @SubmodelBuilder submodels: @escaping () -> [Submodel] = { [] },
        @PipelineBuilder pipelines: @escaping (Interactor<State, Command, Effect, Event>) -> [Pipeline] = { _ in [] }
    ) {
        self.spec = spec
        self.onEnter = onEnter
        self.onExit = onExit
        self.submodelsFactory = submodels
        self.pipelinesFactory = pipelines
    }
    
    func activateOnDemand(environ: Environ, loggable: Loggable?, modelUid: String, modelId: String, state: State, interactor: Interactor<State, Command, Effect, Event>) async {
        if !isActive && spec.isSatisfiedBy(state) {
            onEnter(environ, state)
            submodels = submodelsFactory()
            submodels.forEach { submodel in
                submodel.setUp(environ: environ, hostId: modelId)
            }
            pipelines = pipelinesFactory(interactor)
            await pipelines.forEachAsync { pipeline in
                await pipeline.start(loggable: loggable, modelId: modelUid, onStatus: { pipeStatus in
                    switch pipeStatus {
                    case .start(let pipeId, let time):
                        loggable?.info("[\(modelUid)|\(pipeline.id)|\(pipeId)] START time: \(Date(milliseconds: time).defaultFormat)")
                    case .restart(let pipeId, let error, let time, let executionInterval):
                        loggable?.warn("[\(modelUid)|\(pipeline.id)|\(pipeId)] RESTART error: \(error), time: \(Date(milliseconds: time).defaultFormat), executionInterval: \(executionInterval) millis")
                    case .interrupt(let pipeId, let error, let time, let executionInterval):
                        loggable?.error("[\(modelUid)|\(pipeline.id)|\(pipeId)] INTERRUPT error: \(error), time: \(Date(milliseconds: time).defaultFormat), executionInterval: \(executionInterval) millis")
                        pipeline.restart()
                    case .stop(let pipeId, let time, let executionInterval):
                        loggable?.info("[\(modelUid)|\(pipeline.id)|\(pipeId)] STOP time: \(Date(milliseconds: time).defaultFormat), executionInterval: \(executionInterval) millis")
                    case .finish(let pipeId, let time, let executionInterval):
                        loggable?.info("[\(modelUid)|\(pipeline.id)|\(pipeId)] FINISH time: \(Date(milliseconds: time).defaultFormat), executionInterval: \(executionInterval) millis")
                    case .launch(let pipeId, let time):
                        loggable?.debug("[\(modelUid)|\(pipeline.id)|\(pipeId)] LAUNCH time: \(Date(milliseconds: time).defaultFormat)")
                    case .success(let pipeId, let time, let iterationInterval):
                        loggable?.debug("[\(modelUid)|\(pipeline.id)|\(pipeId)] SUCCESS time: \(Date(milliseconds: time).defaultFormat), iterationInterval: \(iterationInterval) millis")
                    case .failure(let pipeId, let error, let time, let iterationInterval):
                        loggable?.warn("[\(modelUid)|\(pipeline.id)|\(pipeId)] FAILURE error: \(error), time: \(Date(milliseconds: time).defaultFormat), iterationInterval: \(iterationInterval) millis")
                    }
                })
            }
            isActive = true
        }
    }
    
    func deactivateOnDemand(environ: Environ, state: State, force: Bool = false) {
        if isActive && (!spec.isSatisfiedBy(state) || force) {
            pipelines.forEach { $0.stop() }
            pipelines.removeAll()
            submodels.forEach { $0.tearDown() }
            submodels.removeAll()
            onExit(environ, state)
            isActive = false
        }
    }
    
}
