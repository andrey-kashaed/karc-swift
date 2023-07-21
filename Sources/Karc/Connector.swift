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

public final class Connector<Input: Sendable, Output: Sendable>: Scope {
    
    public let uid: AnyUid
    private let openGate: @Sendable (Environ) async -> Void
    private let closeGate: @Sendable (Environ) async -> Void
    
    public init<Id: Equatable & Hashable & Sendable>(
        tag: String,
        id: Id = DefaultId.shared,
        mode: Gate<Input, Output>.Mode,
        scheme: Gate<Input, Output>.Scheme,
        capacity: Int = Int.max
    ) {
        let gateUid = Uid(tag: tag, id: id).asAny
        uid = gateUid
        openGate = { environ in
            try? await environ.openGate(uid: gateUid, inputType: Input.self, outputType: Output.self, mode: mode, scheme: scheme, capacity: capacity)
        }
        closeGate = { environ in
            try? await environ.closeGate(uid: gateUid, inputType: Input.self, outputType: Output.self)
        }
    }
    
    public func activate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await openGate(environ)
    }
    
    public func deactivate(environ: Environ, logger: Logger, modelUid: AnyUid) async {
        await closeGate(environ)
    }
    
}
