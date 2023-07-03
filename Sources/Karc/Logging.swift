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

import OSLog

public struct LogPriority {
    public static let highest = 5
    public static let high = 4
    public static let medium = 3
    public static let low = 2
    public static let lowest = 1
}

public struct LogLevels: OptionSet {
    public static let trace = LogLevels(rawValue: 1 << 0)
    public static let debug = LogLevels(rawValue: 1 << 1)
    public static let info = LogLevels(rawValue: 1 << 2)
    public static let warning = LogLevels(rawValue: 1 << 3)
    public static let error = LogLevels(rawValue: 1 << 4)
    public static let all: LogLevels = [.trace, .debug, .info, .warning, .error]
    public let rawValue: UInt
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
}

public struct Logger: Sendable {
    
    private let logs: [Log]
    private let enabled: Bool
    
    public init(logs: [Log], enabled: Bool) {
        self.logs = logs
        self.enabled = enabled
    }
    
    public func error(priority: Int = LogPriority.highest, _ message: String) {
        guard enabled else { return }
        for log in logs {
            Task.detached {
                await log.error(priority: priority, message)
            }
        }
    }
    
    public func warning(priority: Int = LogPriority.high, _ message: String) {
        guard enabled else { return }
        for log in logs {
            Task.detached {
                await log.warning(priority: priority, message)
            }
        }
    }
    
    public func info(priority: Int = LogPriority.medium, _ message: String) {
        guard enabled else { return }
        for log in logs {
            Task.detached {
                await log.info(priority: priority, message)
            }
        }
    }
    
    public func debug(priority: Int = LogPriority.low, _ message: String) {
        guard enabled else { return }
        for log in logs {
            Task.detached {
                await log.debug(priority: priority, message)
            }
        }
    }
    
    public func trace(priority: Int = LogPriority.lowest, _ message: String) {
        guard enabled else { return }
        for log in logs {
            Task.detached {
                await log.trace(priority: priority, message)
            }
        }
    }
    
}

public protocol Log: Sendable {
    var logLevels: LogLevels { get }
    var minPriority: Int { get }
    func error(_ message: String) async
    func warning(_ message: String) async
    func info(_ message: String) async
    func debug(_ message: String) async
    func trace(_ message: String) async
}

public extension Log {
    func error(priority: Int, _ message: String) async {
        if logLevels.contains(.error) && priority >= self.minPriority {
            await error(message)
        }
    }
    func warning(priority: Int, _ message: String) async {
        if logLevels.contains(.warning) && priority >= self.minPriority {
            await warning(message)
        }
    }
    func info(priority: Int, _ message: String) async {
        if logLevels.contains(.info) && priority >= self.minPriority {
            await info(message)
        }
    }
    func debug(priority: Int, _ message: String) async {
        if logLevels.contains(.debug) && priority >= self.minPriority {
            await debug(message)
        }
    }
    func trace(priority: Int, _ message: String) async {
        if logLevels.contains(.trace) && priority >= self.minPriority {
            await trace(message)
        }
    }
}

public actor DefaultLog: Log {
    
    public static let shared = DefaultLog(logLevels: LogLevels.all, minPriority: LogPriority.lowest)
    
    public let logLevels: LogLevels
    
    public let minPriority: Int
    
    private let osLogger = os.Logger()
    
    public init(logLevels: LogLevels, minPriority: Int) {
        self.logLevels = logLevels
        self.minPriority = minPriority
    }
    
    public func error(_ message: String) {
        osLogger.error("\n[ERROR] \(message)")
    }
    
    public func warning(_ message: String) {
        osLogger.warning("\n[WARNING] \(message)")
    }
    
    public func info(_ message: String) {
        osLogger.info("\n[INFO] \(message)")
    }
    
    public func debug(_ message: String) {
        osLogger.debug("\n[DEBUG] \(message)")
    }
    
    public func trace(_ message: String) {
        osLogger.trace("\n[TRACE] \(message)")
    }
    
}
