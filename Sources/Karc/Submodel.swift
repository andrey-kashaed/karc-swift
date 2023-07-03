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

public final class Submodel: Scope {
    
    public let uid: AnyUid
    private let settingUpOperation: @Sendable (Environ) async -> Void
    private let tearingDownOperation: @Sendable () async -> Void
    
    internal init<Model, Domain, Id: Equatable & Hashable & Sendable, State: Equatable & Sendable & Initable, Command, Effect, Event>(
        type: Model.Type,
        id: Id,
        state: State
    ) where Model: Karc.Model<Domain, Id, State, Command, Effect, Event>, Domain: Karc.Domain<Id, State, Command, Event> {
        uid = Uid(tag: String(describing: Model.self), id: id).asAny
        self.settingUpOperation = { environ in
            await Model.setUp(Model.Config(environ: environ, id: id, state: state))
        }
        self.tearingDownOperation = {
            await Model.tearDown(id: id)
        }
    }
    
    public func activate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await settingUpOperation(environ)
    }
    
    public func deactivate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await tearingDownOperation()
    }
    
}
