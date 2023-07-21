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

public struct Injector<R>: Scope {
    
    public let uid: AnyUid
    private let acquireResource: @Sendable (Environ) async -> Void
    private let releaseResource: @Sendable (Environ) async -> Void
    
    public init<Id: Equatable & Hashable & Sendable>(id: Id = DefaultId.shared) {
        let resourceUid = Uid(tag: String(describing: R.self), id: id).asAny
        uid = resourceUid
        acquireResource = { environ in
            try? await environ.acquireResource(uid: resourceUid)
        }
        releaseResource = { environ in
            try? await environ.releaseResource(uid: resourceUid)
        }
    }
    
    public func activate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await acquireResource(environ)
    }
    
    public func deactivate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await releaseResource(environ)
    }
    
}
