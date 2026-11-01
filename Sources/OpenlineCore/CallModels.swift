// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum CallDirection: String, Codable, Sendable {
    case incoming, outgoing
}

public enum CallState: Equatable, Sendable {
    case idle
    case incoming
    case outgoing
    case connecting
    case remoteRinging
    case established
    case holding
    case held
    case resuming
    case transferring
    case ending
    case ended
    case failed

    public var isTerminal: Bool { self == .ended || self == .failed }
    public var isLive: Bool { self != .idle && !isTerminal }
    public var isOnHold: Bool { self == .held || self == .holding || self == .resuming }
    public var isConnected: Bool {
        switch self {
        case .established, .holding, .held, .resuming, .transferring: true
        default: false
        }
    }
}

public enum CallEvent: Equatable, Sendable {
    case placed
    case received
    case trying
    case remoteRinging
    case connecting
    case confirmed
    case holdRequested
    case holdConfirmed
    case holdRejected
    case resumeRequested
    case resumeConfirmed
    case resumeRejected
    case transferRequested
    case transferFailed
    case hangupRequested
    case disconnected(answered: Bool)
}

public enum CallTransition {
    /// The next state, or nil when `event` is not valid in `state`. Engine
    /// callbacks can repeat or cross with user actions, so nil means "ignore".
    public static func next(from state: CallState, on event: CallEvent) -> CallState? {
        if state.isTerminal { return nil }
        switch (state, event) {
        case (.idle, .placed): return .outgoing
        case (.idle, .received): return .incoming

        case (.outgoing, .trying): return .connecting
        case (.outgoing, .remoteRinging), (.connecting, .remoteRinging): return .remoteRinging
        case (.outgoing, .connecting), (.remoteRinging, .connecting), (.incoming, .connecting): return .connecting
        case (.outgoing, .confirmed), (.connecting, .confirmed), (.remoteRinging, .confirmed), (.incoming, .confirmed):
            return .established

        case (.established, .holdRequested): return .holding
        case (.holding, .holdConfirmed): return .held
        case (.holding, .holdRejected): return .established
        case (.held, .resumeRequested): return .resuming
        case (.resuming, .resumeConfirmed): return .established
        case (.resuming, .resumeRejected): return .held

        case (.established, .transferRequested), (.held, .transferRequested): return .transferring
        case (.transferring, .transferFailed): return .established

        case (.ending, .hangupRequested): return nil
        case (_, .hangupRequested) where state != .idle: return .ending
        case (.ending, .disconnected): return .ended
        case (_, .disconnected(let answered)) where state != .idle:
            return answered ? .ended : .failed
        default: return nil
        }
    }
}

public struct NegotiatedMedia: Equatable, Sendable {
    public var codec: String
    public var clockRate: Int
    public var remoteAddress: String
    public var txPackets: Int
    public var rxPackets: Int
    public var rxLost: Int
    public var rxJitterMsec: Int
    public var rttMsec: Int
    public var rxLevel: Int
    public var txLevel: Int

    public init(codec: String, clockRate: Int, remoteAddress: String, txPackets: Int, rxPackets: Int,
                rxLost: Int, rxJitterMsec: Int, rttMsec: Int, rxLevel: Int, txLevel: Int) {
        self.codec = codec
        self.clockRate = clockRate
        self.remoteAddress = remoteAddress
        self.txPackets = txPackets
        self.rxPackets = rxPackets
        self.rxLost = rxLost
        self.rxJitterMsec = rxJitterMsec
        self.rttMsec = rttMsec
        self.rxLevel = rxLevel
        self.txLevel = txLevel
    }
}

public enum TransferStatus: Equatable, Sendable {
    case none
    case inProgress(destination: String)
    case failed(code: Int, reason: String)
}

public struct SIPCall: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var engineHandle: String?
    public var sipCallID: String?
    public let accountID: UUID
    public let remote: CallerIdentity
    /// Exactly what the user dialled; `remote` can differ for incoming calls.
    public let dialTarget: String
    public let direction: CallDirection
    public var contactID: UUID?
    public var contactName: String?
    public private(set) var state: CallState
    public var isMuted = false
    public var isRemoteHold = false
    public var transfer: TransferStatus = .none
    public var media: NegotiatedMedia?
    public var failureCode: Int?
    public var failureReason: String?
    public let createdAt: Date
    public var answeredAt: Date?
    public var endedAt: Date?
    /// True once the user, not the far end, chose to end or decline the call.
    public var endedLocally = false
    public var rejectedByPolicy = false

    public init(id: UUID = UUID(), accountID: UUID, remote: CallerIdentity, dialTarget: String,
                direction: CallDirection, createdAt: Date = Date()) {
        self.id = id
        self.accountID = accountID
        self.remote = remote
        self.dialTarget = dialTarget
        self.direction = direction
        self.createdAt = createdAt
        self.state = .idle
    }

    @discardableResult
    public mutating func apply(_ event: CallEvent) -> Bool {
        guard let next = CallTransition.next(from: state, on: event) else { return false }
        state = next
        return true
    }
}

public enum CallOutcome: String, Codable, CaseIterable, Sendable {
    case answered, missed, declined, busy, cancelled, failed

    public static func classify(direction: CallDirection, answered: Bool, endedLocally: Bool,
                                rejectedByPolicy: Bool, statusCode: Int) -> CallOutcome {
        if answered { return .answered }
        switch direction {
        case .incoming:
            if rejectedByPolicy { return .missed }
            return endedLocally ? .declined : .missed
        case .outgoing:
            if endedLocally { return .cancelled }
            switch statusCode {
            case 486, 600: return .busy
            case 603: return .declined
            default: return .failed
            }
        }
    }
}

public struct CallHistoryEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var dialTarget: String
    public var displayIdentity: String
    public var accountID: UUID
    public var direction: CallDirection
    public var outcome: CallOutcome
    public var startedAt: Date
    public var answeredAt: Date?
    public var endedAt: Date
    public var contactID: UUID?
    public var sipStatus: Int?
    public var failureDetail: String?

    public init(id: UUID, dialTarget: String, displayIdentity: String, accountID: UUID, direction: CallDirection,
                outcome: CallOutcome, startedAt: Date, answeredAt: Date?, endedAt: Date, contactID: UUID?,
                sipStatus: Int?, failureDetail: String?) {
        self.id = id
        self.dialTarget = dialTarget
        self.displayIdentity = displayIdentity
        self.accountID = accountID
        self.direction = direction
        self.outcome = outcome
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
        self.contactID = contactID
        self.sipStatus = sipStatus
        self.failureDetail = failureDetail
    }

    public var connectedDuration: TimeInterval { answeredAt.map { max(0, endedAt.timeIntervalSince($0)) } ?? 0 }

    public init?(call: SIPCall, endedAt: Date = Date()) {
        guard call.state.isTerminal else { return nil }
        let outcome = CallOutcome.classify(direction: call.direction, answered: call.answeredAt != nil,
                                           endedLocally: call.endedLocally, rejectedByPolicy: call.rejectedByPolicy,
                                           statusCode: call.failureCode ?? 0)
        self.init(id: call.id, dialTarget: call.dialTarget,
                  displayIdentity: call.remote.displayName ?? call.remote.user ?? call.remote.uri,
                  accountID: call.accountID, direction: call.direction, outcome: outcome, startedAt: call.createdAt,
                  answeredAt: call.answeredAt, endedAt: call.endedAt ?? endedAt, contactID: call.contactID,
                  sipStatus: call.failureCode, failureDetail: call.failureReason)
    }
}

public enum HistoryFilter: String, CaseIterable, Sendable {
    case all, incoming, outgoing, missed, failed, declined

    public func matches(_ entry: CallHistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .incoming: entry.direction == .incoming
        case .outgoing: entry.direction == .outgoing
        case .missed: entry.outcome == .missed
        case .failed: entry.outcome == .failed || entry.outcome == .busy
        case .declined: entry.outcome == .declined
        }
    }
}

public enum IncomingCallDecision: Equatable, Sendable {
    case present
    case rejectBusy
    case rejectDoNotDisturb

    public static func decide(hasLiveCall: Bool, doNotDisturb: Bool) -> IncomingCallDecision {
        if hasLiveCall { return .rejectBusy }
        return doNotDisturb ? .rejectDoNotDisturb : .present
    }

    /// Both rejections answer 486 Busy Here: it is the response PBXs route to
    /// voicemail or a follow-me rule, unlike 603 which often ends the attempt.
    public static let busyHere = 486
}
