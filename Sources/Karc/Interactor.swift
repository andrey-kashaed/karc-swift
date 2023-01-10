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

public struct Interactor<State, Command, Effect, Event> {
    public unowned let environ: Environ
    internal let stateGetter: () async -> State
    public let commandSource: AnySource<Command, Any>
    public let commandDrain: AnyDrain<Command, Any>
    public let effectDrain: AnyDrain<[Effect], [Event]>
    public let eventSource: AnySource<Event, Void>
    public var state: State {
        get async {
            await stateGetter()
        }
    }
}
