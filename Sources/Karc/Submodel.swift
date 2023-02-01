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

public class Submodel {
    
    private var settingUpBlock: (Environ) -> Void
    private var tearingDownBlock: () -> Void
    
    internal init<Model, Domain, State: Equatable & Initable, Command, Effect, Event>(
        type: Model.Type,
        id: String,
        state: State
    ) where Model: Karc.Model<Domain, State, Command, Effect, Event>, Domain: Karc.Domain<State, Command, Event> {
        self.settingUpBlock = { environ in
            Model.setUp(Model.Config(environ: environ, id: id, state: state))
        }
        self.tearingDownBlock = {
            Model.tearDown(id: id)
        }
    }
    
    internal func setUp(environ: Environ, hostId: String) {
        settingUpBlock(environ)
    }
    
    internal func tearDown() {
        tearingDownBlock()
    }
    
}

@resultBuilder
public struct SubmodelBuilder {
    
    public static func buildBlock() -> [Submodel] {
        []
    }
    
    public static func buildBlock(_ submodels: [Submodel]...) -> [Submodel] {
        submodels.flatMap { $0 }
    }
    
    public static func buildArray(_ submodels: [[Submodel]]) -> [Submodel] {
        submodels.flatMap { $0 }
    }
    
    public static func buildExpression(_ submodel: Submodel) -> [Submodel] {
        [submodel]
    }
    
}
