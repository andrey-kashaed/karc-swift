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

public protocol Scope: Sendable {
    
    var uid: AnyUid { get }
    
    func activate(environ: Environ, logger: Logger, modelUid: AnyUid) async
    
    func deactivate(environ: Environ, logger: Logger, modelUid: AnyUid) async
    
}

@resultBuilder
public struct ScopesBuilder: Sendable {
    
    public static func buildBlock() -> [Scope] {
        []
    }
    
    public static func buildBlock(_ scopes: [Scope]...) -> [Scope] {
        scopes.flatMap { $0 }
    }
    
    public static func buildArray(_ scopes: [[Scope]]) -> [Scope] {
        scopes.flatMap { $0 }
    }
    
    public static func buildExpression(_ scope: Scope) -> [Scope] {
        [scope]
    }
    
    public static func buildOptional(_ scopes: [Scope]?) -> [Scope] {
        scopes ?? []
    }
    
    public static func buildEither(first scopes: [Scope]) -> [Scope] {
        scopes
    }

    public static func buildEither(second scopes: [Scope]) -> [Scope] {
        scopes
    }
    
}
