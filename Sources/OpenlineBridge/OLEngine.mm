// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later

#import "OLEngine.h"

#include <pjsua2.hpp>
#include <pjlib-util/resolver.h>
#include <arpa/inet.h>
#include <deque>
#include <map>
#include <memory>
#include <resolv.h>
#include <string>
#include <vector>

NSErrorDomain const OLEngineErrorDomain = @"org.openline.engine";

using std::string;

namespace {

NSString *ns(const string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
string cpp(NSString *_Nullable s) { return s ? string(s.UTF8String) : string(); }

NSError *makeError(const pj::Error &e) {
    return [NSError errorWithDomain:OLEngineErrorDomain
                               code:e.status
                           userInfo:@{NSLocalizedDescriptionKey : ns(e.info())}];
}

NSError *makeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:OLEngineErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSError *unknownCall() { return makeError(-1, @"The call no longer exists."); }
NSError *unknownAccount() { return makeError(-2, @"The account is not loaded in the SIP engine."); }
NSError *notRunning() { return makeError(-3, @"The SIP engine is not running."); }

OLFailureCategory categorize(pj_status_t status) {
    if (status == PJ_SUCCESS) return OLFailureNone;
    if (status == PJ_ERESOLVE) return OLFailureDNS;
    if (status >= PJLIB_UTIL_ERRNO_START && status < PJLIB_UTIL_ERRNO_START + PJ_ERRNO_SPACE_SIZE) return OLFailureDNS;
    return OLFailureNetwork;
}

}  // namespace

// MARK: - Value objects

@interface OLEvent ()
@property (nonatomic, readwrite) OLEventKind kind;
@property (nonatomic, readwrite, copy, nullable) NSString *accountID;
@property (nonatomic, readwrite, copy, nullable) NSString *callHandle;
@property (nonatomic, readwrite, copy, nullable) NSString *sipCallID;
@property (nonatomic, readwrite, copy, nullable) NSString *remoteURI;
@property (nonatomic, readwrite, copy, nullable) NSString *reason;
@property (nonatomic, readwrite, copy, nullable) NSString *digit;
@property (nonatomic, readwrite) NSInteger statusCode;
@property (nonatomic, readwrite) NSInteger expiration;
@property (nonatomic, readwrite) OLCallPhase callPhase;
@property (nonatomic, readwrite) OLMediaPhase mediaPhase;
@property (nonatomic, readwrite) OLFailureCategory failure;
@property (nonatomic, readwrite) BOOL renewing;
@property (nonatomic, readwrite) BOOL finalNotify;
@end
@implementation OLEvent
@end

@implementation OLAccountSpec
- (instancetype)init {
    if ((self = [super init])) {
        _realm = @"*";
        _registrationInterval = 300;
        _rewriteContact = YES;
    }
    return self;
}
@end

@implementation OLEngineConfig
@end

@interface OLAudioDeviceInfo ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) NSInteger inputChannels;
@property (nonatomic, readwrite) NSInteger outputChannels;
@end
@implementation OLAudioDeviceInfo
@end

@interface OLCallStats ()
@property (nonatomic, readwrite, copy) NSString *codec;
@property (nonatomic, readwrite) NSInteger clockRate;
@property (nonatomic, readwrite, copy) NSString *remoteAddress;
@property (nonatomic, readwrite) NSInteger txPackets;
@property (nonatomic, readwrite) NSInteger rxPackets;
@property (nonatomic, readwrite) NSInteger rxLost;
@property (nonatomic, readwrite) NSInteger rxJitterMsec;
@property (nonatomic, readwrite) NSInteger rttMsec;
@property (nonatomic, readwrite) NSInteger rxLevel;
@property (nonatomic, readwrite) NSInteger txLevel;
@end
@implementation OLCallStats
@end

// MARK: - PJSUA2 subclasses

namespace {

class Core;

class CallImpl : public pj::Call {
  public:
    CallImpl(Core &core, pj::Account &account, string accountID, int callID = PJSUA_INVALID_ID)
        : pj::Call(account, callID), core(core), accountID(std::move(accountID)),
          handle(cpp(NSUUID.UUID.UUIDString)) {}

    void onCallState(pj::OnCallStateParam &) override;
    void onCallMediaState(pj::OnCallMediaStateParam &) override;
    void onCallTsxState(pj::OnCallTsxStateParam &) override;
    void onCallTransferRequest(pj::OnCallTransferRequestParam &) override;
    void onCallTransferStatus(pj::OnCallTransferStatusParam &) override;
    void onDtmfDigit(pj::OnDtmfDigitParam &) override;

    /// Routes every active audio stream through the conference bridge.
    void routeAudio();

    Core &core;
    string accountID;
    string handle;
    bool muted = false;
};

class AccountImpl : public pj::Account {
  public:
    AccountImpl(Core &core, string accountID) : core(core), accountID(std::move(accountID)) {}
    ~AccountImpl() override { shutdown(); }

    void onRegStarted(pj::OnRegStartedParam &) override;
    void onRegState(pj::OnRegStateParam &) override;
    void onIncomingCall(pj::OnIncomingCallParam &) override;

    Core &core;
    string accountID;
};

class EndpointImpl : public pj::Endpoint {
  public:
    explicit EndpointImpl(Core &core) : core(core) {}
    void onTransportState(const pj::OnTransportStateParam &) override;
    Core &core;
};

class LogWriterImpl : public pj::LogWriter {
  public:
    explicit LogWriterImpl(OLLogHandler handler) : handler(handler) {}
    void write(const pj::LogEntry &entry) override { handler(ns(entry.msg)); }
    OLLogHandler handler;
};

/// Engine state. Everything here runs on the SIP thread, so nothing is locked.
class Core {
  public:
    explicit Core(OLEventHandler handler) : emit(handler) {}

    void start(OLEngineConfig *config, int logLevel, OLLogHandler logHandler);
    void shutdown();

    void addAccount(OLAccountSpec *spec, bool registerNow);
    CallImpl *call(NSString *handle) {
        auto it = calls.find(cpp(handle));
        return it == calls.end() ? nullptr : it->second.get();
    }
    AccountImpl *account(NSString *accountID) {
        auto it = accounts.find(cpp(accountID));
        return it == accounts.end() ? nullptr : it->second.get();
    }
    CallImpl *adopt(std::unique_ptr<CallImpl> call) {
        CallImpl *raw = call.get();
        calls[raw->handle] = std::move(call);
        return raw;
    }

    /// PJSUA2 forbids deleting a Call inside its own callback.
    void retire(const string &handle) { retiring.push_back(handle); }
    void reapRetired() {
        for (auto &handle : retiring) calls.erase(handle);
        retiring.clear();
    }

    pj::AudioMedia *micSource();
    pj::AudioMedia *speakerSink();
    void startRingback();
    void stopRingback();

    void refreshAudioDevices();
    void applyAudioSelection();
    int deviceIndex(const string &name, bool capture);

    void updateNameservers();
    void updateSTUN(NSArray<NSString *> *servers);

    OLEventHandler emit;
    std::unique_ptr<EndpointImpl> endpoint;
    std::map<string, std::unique_ptr<AccountImpl>> accounts;
    std::map<string, std::unique_ptr<CallImpl>> calls;
    std::vector<string> retiring;
    std::map<std::pair<int, bool>, pj::TransportId> transports;
    std::unique_ptr<pj::ToneGenerator> ringback;
    bool ringbackPlaying = false;
    bool nullAudio = false;
    std::unique_ptr<pj::AudioMediaPlayer> testSource;
    std::unique_ptr<pj::AudioMediaRecorder> testRecorder;
    string selectedInput;
    string selectedOutput;
    int lastCaptureIndex = PJMEDIA_AUD_DEFAULT_CAPTURE_DEV;
    int lastPlaybackIndex = PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV;
    NSDate *lastTLSFailure = nil;
};

std::vector<string> systemNameservers() {
    std::vector<string> result;
    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) return result;
    union res_sockaddr_union servers[MAXNS];
    int count = res_getservers(&state, servers, MAXNS);
    for (int i = 0; i < count; i++) {
        char buffer[INET6_ADDRSTRLEN] = {0};
        if (servers[i].sin.sin_family == AF_INET &&
            inet_ntop(AF_INET, &servers[i].sin.sin_addr, buffer, sizeof(buffer))) {
            result.emplace_back(buffer);
        }
    }
    res_ndestroy(&state);
    return result;
}

void Core::start(OLEngineConfig *config, int logLevel, OLLogHandler logHandler) {
    nullAudio = config.nullAudio;
    // PJLIB logs to stdout until libInit installs the configured writer.
    pj_log_set_level(0);
    endpoint = std::make_unique<EndpointImpl>(*this);
    endpoint->libCreate();

    pj::EpConfig cfg;
    cfg.uaConfig.userAgent = cpp(config.userAgent);
    cfg.uaConfig.threadCnt = 0;
    cfg.uaConfig.mainThreadOnly = true;
    cfg.uaConfig.maxCalls = PJSUA_MAX_CALLS;
    cfg.uaConfig.stunIgnoreFailure = true;
    cfg.uaConfig.nameserver = systemNameservers();
    cfg.medConfig.clockRate = 48000;
    cfg.medConfig.channelCount = 1;
    cfg.medConfig.noVad = true;
    cfg.medConfig.ecTailLen = 200;
    cfg.medConfig.ecOptions = PJMEDIA_ECHO_WEBRTC_AEC3;
    cfg.medConfig.sndAutoCloseTime = 1;
    cfg.logConfig.level = 0;
    cfg.logConfig.consoleLevel = 0;
    if (logHandler && logLevel > 0) {
        // The endpoint owns the writer and deletes it in libDestroy.
        cfg.logConfig.writer = new LogWriterImpl(logHandler);
        cfg.logConfig.level = (unsigned)logLevel;
        cfg.logConfig.consoleLevel = (unsigned)logLevel;
        cfg.logConfig.msgLogging = logLevel >= 4;
    } else {
        cfg.logConfig.msgLogging = 0;
    }
    endpoint->libInit(cfg);

    pj::TransportConfig plain;
    plain.port = 0;
    transports[{OLTransportUDP, false}] = endpoint->transportCreate(PJSIP_TRANSPORT_UDP, plain);
    transports[{OLTransportTCP, false}] = endpoint->transportCreate(PJSIP_TRANSPORT_TCP, plain);
    pj::TransportConfig tls;
    tls.port = 0;
    tls.tlsConfig.verifyServer = !config.skipTLSVerificationForTesting;
    tls.tlsConfig.method = PJSIP_TLSV1_2_METHOD;
    transports[{OLTransportTLS, false}] = endpoint->transportCreate(PJSIP_TRANSPORT_TLS, tls);
    // IPv6 listeners are best-effort: hosts without IPv6 stay fully functional.
    try {
        transports[{OLTransportUDP, true}] = endpoint->transportCreate(PJSIP_TRANSPORT_UDP6, plain);
        transports[{OLTransportTCP, true}] = endpoint->transportCreate(PJSIP_TRANSPORT_TCP6, plain);
        transports[{OLTransportTLS, true}] = endpoint->transportCreate(PJSIP_TRANSPORT_TLS6, tls);
    } catch (const pj::Error &) {
    }

    if (nullAudio) endpoint->audDevManager().setNullDev();
    endpoint->libStart();

    if (nullAudio) {
        if (config.sourceWAV) {
            testSource = std::make_unique<pj::AudioMediaPlayer>();
            testSource->createPlayer(cpp(config.sourceWAV), 0);
        }
        if (config.recordWAV) {
            testRecorder = std::make_unique<pj::AudioMediaRecorder>();
            testRecorder->createRecorder(cpp(config.recordWAV));
        }
    }
    ringback = std::make_unique<pj::ToneGenerator>();
    ringback->createToneGenerator(48000, 1);
}

void Core::shutdown() {
    if (!endpoint) return;
    try {
        stopRingback();
        endpoint->hangupAllCalls();
        for (int i = 0; i < 20 && !calls.empty(); i++) {
            endpoint->libHandleEvents(10);
            reapRetired();
        }
        calls.clear();
        ringback.reset();
        testSource.reset();
        testRecorder.reset();
        accounts.clear();
        for (int i = 0; i < 50; i++) endpoint->libHandleEvents(10);
        endpoint->libDestroy();
    } catch (const pj::Error &) {
    }
    endpoint.reset();
}

void Core::addAccount(OLAccountSpec *spec, bool registerNow) {
    pj::AccountConfig cfg;
    cfg.idUri = cpp(spec.idURI);
    cfg.regConfig.registrarUri = cpp(spec.registrarURI);
    cfg.regConfig.registerOnAdd = registerNow;
    cfg.regConfig.timeoutSec = (unsigned)spec.registrationInterval;
    // Retries are scheduled by ReconnectPolicy so they are bounded and testable.
    cfg.regConfig.retryIntervalSec = 0;
    cfg.regConfig.firstRetryIntervalSec = 0;
    cfg.regConfig.randomRetryIntervalSec = 0;
    cfg.regConfig.dropCallsOnFail = false;
    cfg.sipConfig.authCreds.push_back(pj::AuthCredInfo("digest", cpp(spec.realm), cpp(spec.authUsername), 0, cpp(spec.password)));
    if (spec.proxyURI.length > 0) cfg.sipConfig.proxies.push_back(cpp(spec.proxyURI));

    auto transport = transports.find({(int)spec.transport, (bool)spec.preferIPv6});
    if (transport == transports.end()) {
        throw pj::Error(PJ_EINVAL, "addAccount", "No listener for this transport and address family", __FILE__, __LINE__);
    }
    cfg.sipConfig.transportId = transport->second;
    cfg.sipConfig.ipv6Use = spec.preferIPv6 ? PJSUA_IPV6_ENABLED_USE_IPV6_ONLY : PJSUA_IPV6_ENABLED_PREFER_IPV4;
    cfg.mediaConfig.ipv6Use = spec.preferIPv6 ? PJSUA_IPV6_ENABLED_USE_IPV6_ONLY : PJSUA_IPV6_ENABLED_PREFER_IPV4;

    cfg.natConfig.sipStunUse = spec.useSTUN ? PJSUA_STUN_USE_DEFAULT : PJSUA_STUN_USE_DISABLED;
    cfg.natConfig.mediaStunUse = spec.useSTUN ? PJSUA_STUN_USE_DEFAULT : PJSUA_STUN_USE_DISABLED;
    cfg.natConfig.iceEnabled = spec.iceEnabled;
    if (spec.turnServer.length > 0) {
        cfg.natConfig.turnEnabled = true;
        cfg.natConfig.turnServer = cpp(spec.turnServer);
        cfg.natConfig.turnUserName = cpp(spec.turnUsername);
        cfg.natConfig.turnPassword = cpp(spec.turnPassword);
    }
    cfg.natConfig.contactRewriteUse = spec.rewriteContact;
    cfg.natConfig.viaRewriteUse = spec.rewriteContact;
    cfg.natConfig.sdpNatRewriteUse = spec.rewriteSDP;
    // RFC 5626 outbound parameters are rejected by some registrars.
    cfg.natConfig.sipOutboundUse = false;

    switch (spec.srtp) {
    case OLSRTPModeDisabled:
        cfg.mediaConfig.srtpUse = PJMEDIA_SRTP_DISABLED;
        cfg.mediaConfig.srtpSecureSignaling = 0;
        break;
    case OLSRTPModeOptional:
        cfg.mediaConfig.srtpUse = PJMEDIA_SRTP_OPTIONAL;
        cfg.mediaConfig.srtpSecureSignaling = spec.transport == OLTransportTLS ? 1 : 0;
        break;
    case OLSRTPModeMandatory:
        cfg.mediaConfig.srtpUse = PJMEDIA_SRTP_MANDATORY;
        cfg.mediaConfig.srtpSecureSignaling = spec.transport == OLTransportTLS ? 1 : 0;
        break;
    }

    auto account = std::make_unique<AccountImpl>(*this, cpp(spec.accountID));
    string id = account->accountID;
    accounts.erase(id);
    AccountImpl *raw = account.get();
    accounts[id] = std::move(account);
    try {
        raw->create(cfg);
    } catch (const pj::Error &) {
        accounts.erase(id);
        throw;
    }
}

pj::AudioMedia *Core::micSource() {
    if (nullAudio) return testSource.get();
    return &endpoint->audDevManager().getCaptureDevMedia();
}

pj::AudioMedia *Core::speakerSink() {
    if (nullAudio) return testRecorder.get();
    return &endpoint->audDevManager().getPlaybackDevMedia();
}

void Core::startRingback() {
    if (ringbackPlaying || nullAudio || !ringback) return;
    try {
        pj::ToneDesc tone;
        tone.freq1 = 440;
        tone.freq2 = 480;
        tone.on_msec = 2000;
        tone.off_msec = 4000;
        tone.volume = 0;
        tone.flags = 0;
        ringback->play({tone}, true);
        ringback->startTransmit(*speakerSink());
        ringbackPlaying = true;
    } catch (const pj::Error &) {
    }
}

void Core::stopRingback() {
    if (!ringbackPlaying) return;
    ringbackPlaying = false;
    try {
        ringback->stopTransmit(*speakerSink());
        ringback->stop();
    } catch (const pj::Error &) {
    }
}

int Core::deviceIndex(const string &name, bool capture) {
    auto fallback = capture ? PJMEDIA_AUD_DEFAULT_CAPTURE_DEV : PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV;
    if (name.empty()) return fallback;
    try {
        auto devices = endpoint->audDevManager().enumDev2();
        for (size_t i = 0; i < devices.size(); i++) {
            bool usable = capture ? devices[i].inputCount > 0 : devices[i].outputCount > 0;
            if (usable && devices[i].name == name) return (int)i;
        }
    } catch (const pj::Error &) {
    }
    return fallback;  // A missing explicit device falls back to the system default.
}

void Core::refreshAudioDevices() {
    if (nullAudio) return;
    endpoint->audDevManager().refreshDevs();
}

void Core::applyAudioSelection() {
    if (nullAudio) return;
    auto &manager = endpoint->audDevManager();
    int capture = deviceIndex(selectedInput, true);
    int playback = deviceIndex(selectedOutput, false);
    manager.setCaptureDev(capture);
    manager.setPlaybackDev(playback);
    lastCaptureIndex = capture;
    lastPlaybackIndex = playback;
}

void Core::updateNameservers() {
    auto servers = systemNameservers();
    if (servers.empty()) return;
    pjsip_endpoint *sip = pjsua_get_pjsip_endpt();
    pj_dns_resolver *resolver = pjsip_endpt_get_resolver(sip);
    if (!resolver) {
        if (pjsip_endpt_create_resolver(sip, &resolver) != PJ_SUCCESS) return;
        pjsip_endpt_set_resolver(sip, resolver);
    }
    std::vector<pj_str_t> addresses;
    for (auto &server : servers) addresses.push_back(pj_str((char *)server.c_str()));
    pj_dns_resolver_set_ns(resolver, (unsigned)addresses.size(), addresses.data(), nullptr);
}

void Core::updateSTUN(NSArray<NSString *> *servers) {
    std::vector<string> storage;
    for (NSString *server in servers) storage.push_back(cpp(server));
    std::vector<pj_str_t> names;
    for (auto &server : storage) names.push_back(pj_str((char *)server.c_str()));
    pjsua_update_stun_servers((unsigned)names.size(), names.data(), PJ_FALSE);
}

void EndpointImpl::onTransportState(const pj::OnTransportStateParam &prm) {
    if (!prm.tlsInfo.isEmpty() && prm.tlsInfo.verifyStatus != 0) core.lastTLSFailure = [NSDate date];
}

void AccountImpl::onRegStarted(pj::OnRegStartedParam &prm) {
    OLEvent *event = [OLEvent new];
    event.kind = OLEventRegistrationStarted;
    event.accountID = ns(accountID);
    event.renewing = prm.renew;
    core.emit(event);
}

void AccountImpl::onRegState(pj::OnRegStateParam &prm) {
    OLEvent *event = [OLEvent new];
    event.kind = OLEventRegistrationChanged;
    event.accountID = ns(accountID);
    event.statusCode = prm.code;
    event.reason = ns(prm.reason);
    event.expiration = prm.expiration;
    event.failure = categorize(prm.status);
    if (core.lastTLSFailure && -core.lastTLSFailure.timeIntervalSinceNow < 5) event.failure = OLFailureTLS;
    core.emit(event);
}

void AccountImpl::onIncomingCall(pj::OnIncomingCallParam &prm) {
    auto call = std::make_unique<CallImpl>(core, *this, accountID, prm.callId);
    CallImpl *raw = core.adopt(std::move(call));
    OLEvent *event = [OLEvent new];
    event.kind = OLEventIncomingCall;
    event.accountID = ns(accountID);
    event.callHandle = ns(raw->handle);
    try {
        pj::CallInfo info = raw->getInfo();
        event.remoteURI = ns(info.remoteUri);
        event.sipCallID = ns(info.callIdString);
    } catch (const pj::Error &) {
    }
    core.emit(event);
}

void CallImpl::onCallState(pj::OnCallStateParam &) {
    pj::CallInfo info;
    try {
        info = getInfo();
    } catch (const pj::Error &) {
        return;
    }
    OLEvent *event = [OLEvent new];
    event.kind = OLEventCallState;
    event.accountID = ns(accountID);
    event.callHandle = ns(handle);
    event.sipCallID = ns(info.callIdString);
    event.remoteURI = ns(info.remoteUri);
    event.statusCode = info.lastStatusCode;
    event.reason = ns(info.lastReason);
    switch (info.state) {
    case PJSIP_INV_STATE_CALLING: event.callPhase = OLCallPhaseCalling; break;
    case PJSIP_INV_STATE_INCOMING: event.callPhase = OLCallPhaseIncoming; break;
    case PJSIP_INV_STATE_EARLY: event.callPhase = OLCallPhaseEarly; break;
    case PJSIP_INV_STATE_CONNECTING: event.callPhase = OLCallPhaseConnecting; break;
    case PJSIP_INV_STATE_CONFIRMED: event.callPhase = OLCallPhaseConfirmed; break;
    case PJSIP_INV_STATE_DISCONNECTED: event.callPhase = OLCallPhaseDisconnected; break;
    default: event.callPhase = OLCallPhaseNull; break;
    }

    if (info.state == PJSIP_INV_STATE_EARLY && info.role == PJSIP_ROLE_UAC &&
        info.lastStatusCode == PJSIP_SC_RINGING && !hasMedia()) {
        core.startRingback();
    } else if (info.state >= PJSIP_INV_STATE_CONNECTING) {
        core.stopRingback();
    }

    core.emit(event);
    if (info.state == PJSIP_INV_STATE_DISCONNECTED) core.retire(handle);
}

void CallImpl::routeAudio() {
    pj::CallInfo info = getInfo();
    for (const auto &media : info.media) {
        if (media.type != PJMEDIA_TYPE_AUDIO || media.status == PJSUA_CALL_MEDIA_NONE ||
            media.status == PJSUA_CALL_MEDIA_ERROR) {
            continue;
        }
        pj::AudioMedia audio = getAudioMedia((int)media.index);
        pj::AudioMedia *mic = core.micSource();
        pj::AudioMedia *speaker = core.speakerSink();
        if (speaker) audio.startTransmit(*speaker);
        if (mic) {
            // A sendonly hold keeps the stream running, so the microphone must
            // be cut here or the held party would keep hearing the room.
            bool silent = muted || media.status == PJSUA_CALL_MEDIA_LOCAL_HOLD;
            if (silent) {
                mic->stopTransmit(audio);
            } else {
                mic->startTransmit(audio);
            }
        }
    }
}

void CallImpl::onCallMediaState(pj::OnCallMediaStateParam &) {
    OLEvent *event = [OLEvent new];
    event.kind = OLEventCallMedia;
    event.accountID = ns(accountID);
    event.callHandle = ns(handle);
    event.mediaPhase = OLMediaPhaseNone;
    try {
        pj::CallInfo info = getInfo();
        for (const auto &media : info.media) {
            if (media.type != PJMEDIA_TYPE_AUDIO) continue;
            switch (media.status) {
            case PJSUA_CALL_MEDIA_ACTIVE: event.mediaPhase = OLMediaPhaseActive; break;
            case PJSUA_CALL_MEDIA_LOCAL_HOLD: event.mediaPhase = OLMediaPhaseLocalHold; break;
            case PJSUA_CALL_MEDIA_REMOTE_HOLD: event.mediaPhase = OLMediaPhaseRemoteHold; break;
            case PJSUA_CALL_MEDIA_ERROR: event.mediaPhase = OLMediaPhaseError; break;
            default: break;
            }
        }
        // Early media replaces the local ringback tone.
        if (event.mediaPhase == OLMediaPhaseActive) core.stopRingback();
        routeAudio();
    } catch (const pj::Error &e) {
        event.mediaPhase = OLMediaPhaseError;
        event.reason = ns(e.info());
    }
    core.emit(event);
}

void CallImpl::onCallTsxState(pj::OnCallTsxStateParam &prm) {
    if (prm.e.type != PJSIP_EVENT_TSX_STATE) return;
    const pj::SipTransaction &tsx = prm.e.body.tsxState.tsx;
    if (tsx.role != PJSIP_ROLE_UAC || tsx.method != "INVITE" || tsx.statusCode < 300) return;
    if (tsx.state != PJSIP_TSX_STATE_COMPLETED) return;
    try {
        if (getInfo().state != PJSIP_INV_STATE_CONFIRMED) return;
    } catch (const pj::Error &) {
        return;
    }
    OLEvent *event = [OLEvent new];
    event.kind = OLEventCallReinviteFailed;
    event.accountID = ns(accountID);
    event.callHandle = ns(handle);
    event.statusCode = tsx.statusCode;
    event.reason = ns(tsx.statusText);
    core.emit(event);
}

void CallImpl::onCallTransferRequest(pj::OnCallTransferRequestParam &prm) {
    // Being transferred by a peer would start a second call, which the
    // single-call policy of v1 forbids. PBX-side transfers are unaffected.
    prm.statusCode = PJSIP_SC_DECLINE;
}

void CallImpl::onCallTransferStatus(pj::OnCallTransferStatusParam &prm) {
    OLEvent *event = [OLEvent new];
    event.kind = OLEventCallTransferStatus;
    event.accountID = ns(accountID);
    event.callHandle = ns(handle);
    event.statusCode = prm.statusCode;
    event.reason = ns(prm.reason);
    event.finalNotify = prm.finalNotify;
    core.emit(event);
}

void CallImpl::onDtmfDigit(pj::OnDtmfDigitParam &prm) {
    OLEvent *event = [OLEvent new];
    event.kind = OLEventCallDTMFReceived;
    event.accountID = ns(accountID);
    event.callHandle = ns(handle);
    event.digit = ns(prm.digit);
    core.emit(event);
}

}  // namespace

// MARK: - OLEngine

typedef void (^OLJob)(Core &core);

@implementation OLEngine {
    OLEventHandler _eventHandler;
    OLLogHandler _logHandler;
    NSInteger _logLevel;
    NSThread *_thread;
    NSCondition *_condition;
    std::deque<OLJob> _jobs;
    BOOL _running;
    BOOL _stopping;
    void (^_shutdownCompletion)(void);
}

- (instancetype)initWithEventHandler:(OLEventHandler)eventHandler {
    if ((self = [super init])) {
        _eventHandler = [eventHandler copy];
        _condition = [NSCondition new];
    }
    return self;
}

- (void)setLogHandler:(OLLogHandler)handler level:(NSInteger)level {
    _logHandler = [handler copy];
    _logLevel = level;
}

- (BOOL)enqueue:(OLJob)job {
    [_condition lock];
    BOOL accepted = _running && !_stopping;
    if (accepted) _jobs.push_back([job copy]);
    [_condition unlock];
    return accepted;
}

- (void)run:(OLJob)job failed:(void (^)(void))failed {
    if (![self enqueue:job]) failed();
}

- (void)threadMain:(id)configObject {
    OLEngineConfig *config = ((NSArray *)configObject)[0];
    OLCompletion started = ((NSArray *)configObject)[1];
    auto core = std::make_unique<Core>(_eventHandler);
    try {
        core->start(config, (int)_logLevel, _logHandler);
    } catch (const pj::Error &e) {
        [_condition lock];
        _running = NO;
        [_condition unlock];
        started(makeError(e));
        return;
    }
    started(nil);

    for (;;) {
        std::deque<OLJob> pending;
        [_condition lock];
        pending.swap(_jobs);
        BOOL stopping = _stopping;
        [_condition unlock];
        @autoreleasepool {
            for (OLJob job : pending) job(*core);
            core->reapRetired();
            if (stopping) break;
            // Long polls keep an idle softphone from waking the CPU constantly;
            // calls need prompt signalling and DTMF.
            core->endpoint->libHandleEvents(core->calls.empty() ? 50 : 10);
            core->reapRetired();
        }
    }
    core->shutdown();
    core.reset();
    [_condition lock];
    _running = NO;
    void (^finished)(void) = _shutdownCompletion;
    _shutdownCompletion = nil;
    [_condition unlock];
    if (finished) finished();
}

- (void)start:(OLEngineConfig *)config completion:(OLCompletion)completion {
    [_condition lock];
    if (_running) {
        [_condition unlock];
        completion(nil);
        return;
    }
    _running = YES;
    _stopping = NO;
    [_condition unlock];
    _thread = [[NSThread alloc] initWithTarget:self
                                      selector:@selector(threadMain:)
                                        object:@[ config, [completion copy] ]];
    _thread.name = @"org.openline.sip";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    _thread.stackSize = 1024 * 1024;
    [_thread start];
}

- (void)shutdown:(void (^)(void))completion {
    [_condition lock];
    BOOL running = _running;
    if (running) {
        _shutdownCompletion = [completion copy];
        _stopping = YES;
    }
    [_condition unlock];
    if (!running) completion();
}

- (void)addAccount:(OLAccountSpec *)spec registerNow:(BOOL)registerNow completion:(OLCompletion)completion {
    [self run:^(Core &core) {
        try {
            core.addAccount(spec, registerNow);
            completion(nil);
        } catch (const pj::Error &e) {
            completion(makeError(e));
        }
    } failed:^{ completion(notRunning()); }];
}

- (void)removeAccount:(NSString *)accountID completion:(OLCompletion)completion {
    [self run:^(Core &core) {
        core.accounts.erase(cpp(accountID));
        completion(nil);
    } failed:^{ completion(notRunning()); }];
}

- (void)setRegistered:(BOOL)registered account:(NSString *)accountID completion:(OLCompletion)completion {
    [self run:^(Core &core) {
        AccountImpl *account = core.account(accountID);
        if (!account) return completion(unknownAccount());
        try {
            account->setRegistration(registered);
            completion(nil);
        } catch (const pj::Error &e) {
            completion(makeError(e));
        }
    } failed:^{ completion(notRunning()); }];
}

- (void)makeCallTo:(NSString *)uri
           account:(NSString *)accountID
        completion:(void (^)(NSString *, NSError *))completion {
    [self run:^(Core &core) {
        AccountImpl *account = core.account(accountID);
        if (!account) return completion(nil, unknownAccount());
        auto call = std::make_unique<CallImpl>(core, *account, cpp(accountID));
        CallImpl *raw = core.adopt(std::move(call));
        string handle = raw->handle;
        try {
            pj::CallOpParam param(true);
            param.opt.audioCount = 1;
            param.opt.videoCount = 0;
            param.opt.textCount = 0;
            raw->makeCall(cpp(uri), param);
            completion(ns(handle), nil);
        } catch (const pj::Error &e) {
            core.retire(handle);
            completion(nil, makeError(e));
        }
    } failed:^{ completion(nil, notRunning()); }];
}

- (void)withCall:(NSString *)handle
      completion:(OLCompletion)completion
              do:(void (^)(CallImpl *call))body {
    [self run:^(Core &core) {
        CallImpl *call = core.call(handle);
        if (!call) return completion(unknownCall());
        try {
            body(call);
            completion(nil);
        } catch (const pj::Error &e) {
            completion(makeError(e));
        }
    } failed:^{ completion(notRunning()); }];
}

- (void)sendRinging:(NSString *)callHandle completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        pj::CallOpParam param;
        param.statusCode = PJSIP_SC_RINGING;
        call->answer(param);
    }];
}

- (void)answer:(NSString *)callHandle completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        pj::CallOpParam param(true);
        param.statusCode = PJSIP_SC_OK;
        param.opt.audioCount = 1;
        param.opt.videoCount = 0;
        param.opt.textCount = 0;
        call->answer(param);
    }];
}

- (void)hangup:(NSString *)callHandle statusCode:(NSInteger)statusCode completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        pj::CallOpParam param;
        param.statusCode = (pjsip_status_code)statusCode;
        call->hangup(param);
    }];
}

- (void)setHold:(BOOL)hold call:(NSString *)callHandle completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        pj::CallOpParam param(true);
        if (hold) {
            call->setHold(param);
        } else {
            param.opt.flag = PJSUA_CALL_UNHOLD;
            param.opt.audioCount = 1;
            param.opt.videoCount = 0;
            param.opt.textCount = 0;
            call->reinvite(param);
        }
    }];
}

- (void)setMuted:(BOOL)muted call:(NSString *)callHandle completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        call->muted = muted;
        call->routeAudio();
    }];
}

- (void)sendDTMF:(NSString *)digits
          method:(OLDTMFMethod)method
            call:(NSString *)callHandle
      completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        pj::CallSendDtmfParam param;
        param.digits = cpp(digits);
        param.method = method == OLDTMFMethodSIPInfo ? PJSUA_DTMF_METHOD_SIP_INFO : PJSUA_DTMF_METHOD_RFC2833;
        call->sendDtmf(param);
    }];
}

- (void)transfer:(NSString *)callHandle to:(NSString *)uri completion:(OLCompletion)completion {
    [self withCall:callHandle completion:completion do:^(CallImpl *call) {
        pj::CallOpParam param;
        call->xfer(cpp(uri), param);
    }];
}

- (void)statsForCall:(NSString *)callHandle completion:(void (^)(OLCallStats *))completion {
    [self run:^(Core &core) {
        CallImpl *call = core.call(callHandle);
        if (!call) return completion(nil);
        try {
            pj::CallInfo info = call->getInfo();
            for (const auto &media : info.media) {
                if (media.type != PJMEDIA_TYPE_AUDIO || media.status == PJSUA_CALL_MEDIA_NONE) continue;
                pj::StreamInfo stream = call->getStreamInfo(media.index);
                pj::StreamStat stat = call->getStreamStat(media.index);
                pj::AudioMedia audio = call->getAudioMedia((int)media.index);
                OLCallStats *stats = [OLCallStats new];
                stats.codec = ns(stream.codecName);
                stats.clockRate = stream.codecClockRate;
                stats.remoteAddress = ns(stream.remoteRtpAddress);
                stats.txPackets = stat.rtcp.txStat.pkt;
                stats.rxPackets = stat.rtcp.rxStat.pkt;
                stats.rxLost = stat.rtcp.rxStat.loss;
                stats.rxJitterMsec = stat.rtcp.rxStat.jitterUsec.last / 1000;
                stats.rttMsec = stat.rtcp.rttUsec.last / 1000;
                // The bridge port's "tx" is what it passes on from the network.
                stats.rxLevel = audio.getTxLevel();
                stats.txLevel = audio.getRxLevel();
                return completion(stats);
            }
            completion(nil);
        } catch (const pj::Error &) {
            completion(nil);
        }
    } failed:^{ completion(nil); }];
}

- (void)listAudioDevices:(void (^)(NSArray<OLAudioDeviceInfo *> *))completion {
    [self run:^(Core &core) {
        NSMutableArray<OLAudioDeviceInfo *> *result = [NSMutableArray array];
        try {
            core.refreshAudioDevices();
            for (const auto &device : core.endpoint->audDevManager().enumDev2()) {
                OLAudioDeviceInfo *info = [OLAudioDeviceInfo new];
                info.name = ns(device.name);
                info.inputChannels = device.inputCount;
                info.outputChannels = device.outputCount;
                [result addObject:info];
            }
        } catch (const pj::Error &) {
        }
        completion(result);
    } failed:^{ completion(@[]); }];
}

- (void)selectAudioInput:(NSString *)input output:(NSString *)output completion:(OLCompletion)completion {
    [self run:^(Core &core) {
        core.selectedInput = cpp(input);
        core.selectedOutput = cpp(output);
        try {
            core.refreshAudioDevices();
            core.applyAudioSelection();
            completion(nil);
        } catch (const pj::Error &e) {
            completion(makeError(e));
        }
    } failed:^{ completion(notRunning()); }];
}

- (void)audioHardwareChanged {
    [self enqueue:^(Core &core) {
        try {
            core.refreshAudioDevices();
            // Indices shift on refresh and the default may have moved, so the
            // selection is always re-applied; a live call follows the new device.
            core.applyAudioSelection();
        } catch (const pj::Error &) {
        }
        OLEvent *event = [OLEvent new];
        event.kind = OLEventAudioDevicesChanged;
        core.emit(event);
    }];
}

- (void)setCodecOrder:(NSArray<NSString *> *)codecIDs completion:(OLCompletion)completion {
    [self run:^(Core &core) {
        try {
            for (const auto &codec : core.endpoint->codecEnum2()) {
                core.endpoint->codecSetPriority(codec.codecId, 0);
            }
            pj_uint8_t priority = 200;
            for (NSString *codec in codecIDs) {
                core.endpoint->codecSetPriority(cpp(codec), priority);
                priority -= 1;
            }
            completion(nil);
        } catch (const pj::Error &e) {
            completion(makeError(e));
        }
    } failed:^{ completion(notRunning()); }];
}

- (void)availableCodecs:(void (^)(NSArray<NSString *> *))completion {
    [self run:^(Core &core) {
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        try {
            for (const auto &codec : core.endpoint->codecEnum2()) [result addObject:ns(codec.codecId)];
        } catch (const pj::Error &) {
        }
        completion(result);
    } failed:^{ completion(@[]); }];
}

- (void)setSTUNServers:(NSArray<NSString *> *)servers {
    NSArray<NSString *> *copied = [servers copy];
    [self enqueue:^(Core &core) { core.updateSTUN(copied); }];
}

- (void)handleNetworkChange {
    [self enqueue:^(Core &core) {
        core.updateNameservers();
        try {
            pj::IpChangeParam param;
            core.endpoint->handleIpChange(param);
        } catch (const pj::Error &) {
        }
    }];
}

@end
