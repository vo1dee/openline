// Copyright (C) 2026 Openline contributors. SPDX-License-Identifier: GPL-3.0-or-later
//
// Objective-C facade over PJSUA2. No PJSIP type crosses this boundary. Every
// operation is queued to one dedicated SIP thread, which owns the endpoint and
// also receives every engine callback. Completions and events are delivered on
// that thread and must return quickly.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const OLEngineErrorDomain;

typedef NS_ENUM(NSInteger, OLTransport) {
    OLTransportUDP = 0,
    OLTransportTCP = 1,
    OLTransportTLS = 2,
};

typedef NS_ENUM(NSInteger, OLSRTPMode) {
    OLSRTPModeDisabled = 0,
    OLSRTPModeOptional = 1,
    OLSRTPModeMandatory = 2,
};

typedef NS_ENUM(NSInteger, OLDTMFMethod) {
    OLDTMFMethodRFC4733 = 0,
    OLDTMFMethodSIPInfo = 1,
};

typedef NS_ENUM(NSInteger, OLEventKind) {
    OLEventRegistrationStarted,
    OLEventRegistrationChanged,
    OLEventIncomingCall,
    OLEventCallState,
    OLEventCallMedia,
    OLEventCallReinviteFailed,
    OLEventCallTransferStatus,
    OLEventCallDTMFReceived,
    OLEventAudioDevicesChanged,
};

/// Mirrors pjsip_inv_state without exposing it.
typedef NS_ENUM(NSInteger, OLCallPhase) {
    OLCallPhaseNull = 0,
    OLCallPhaseCalling,
    OLCallPhaseIncoming,
    OLCallPhaseEarly,
    OLCallPhaseConnecting,
    OLCallPhaseConfirmed,
    OLCallPhaseDisconnected,
};

typedef NS_ENUM(NSInteger, OLMediaPhase) {
    OLMediaPhaseNone = 0,
    OLMediaPhaseActive,
    OLMediaPhaseLocalHold,
    OLMediaPhaseRemoteHold,
    OLMediaPhaseError,
};

typedef NS_ENUM(NSInteger, OLFailureCategory) {
    OLFailureNone = 0,
    OLFailureDNS,
    OLFailureTLS,
    OLFailureNetwork,
};

/// One immutable engine event. Which properties are set depends on `kind`.
@interface OLEvent : NSObject
@property (nonatomic, readonly) OLEventKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *accountID;
@property (nonatomic, readonly, copy, nullable) NSString *callHandle;
@property (nonatomic, readonly, copy, nullable) NSString *sipCallID;
@property (nonatomic, readonly, copy, nullable) NSString *remoteURI;
@property (nonatomic, readonly, copy, nullable) NSString *reason;
@property (nonatomic, readonly, copy, nullable) NSString *digit;
@property (nonatomic, readonly) NSInteger statusCode;
@property (nonatomic, readonly) NSInteger expiration;
@property (nonatomic, readonly) OLCallPhase callPhase;
@property (nonatomic, readonly) OLMediaPhase mediaPhase;
@property (nonatomic, readonly) OLFailureCategory failure;
@property (nonatomic, readonly) BOOL renewing;
@property (nonatomic, readonly) BOOL finalNotify;
@end

@interface OLAccountSpec : NSObject
@property (nonatomic, copy) NSString *accountID;
@property (nonatomic, copy) NSString *idURI;
@property (nonatomic, copy) NSString *registrarURI;
@property (nonatomic, copy, nullable) NSString *proxyURI;
@property (nonatomic, copy) NSString *authUsername;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *realm;
@property (nonatomic) OLTransport transport;
@property (nonatomic) NSInteger registrationInterval;
@property (nonatomic) BOOL useSTUN;
@property (nonatomic) BOOL iceEnabled;
@property (nonatomic, copy, nullable) NSString *turnServer;
@property (nonatomic, copy, nullable) NSString *turnUsername;
@property (nonatomic, copy, nullable) NSString *turnPassword;
@property (nonatomic) BOOL rewriteContact;
@property (nonatomic) BOOL rewriteSDP;
@property (nonatomic) OLSRTPMode srtp;
@property (nonatomic) OLDTMFMethod dtmfMethod;
@property (nonatomic) BOOL preferIPv6;
@end

@interface OLEngineConfig : NSObject
@property (nonatomic, copy) NSString *userAgent;
/// Integration harness only: no sound hardware. Audio comes from `sourceWAV`
/// and is written to `recordWAV` instead of the microphone and speaker.
@property (nonatomic) BOOL nullAudio;
@property (nonatomic, copy, nullable) NSString *sourceWAV;
@property (nonatomic, copy, nullable) NSString *recordWAV;
/// Integration harness only: the Apple TLS backend trusts the system store and
/// nothing else, so the test PBX's throwaway certificate needs this. The app
/// has no code path that sets it.
@property (nonatomic) BOOL skipTLSVerificationForTesting;
@end

@interface OLAudioDeviceInfo : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSInteger inputChannels;
@property (nonatomic, readonly) NSInteger outputChannels;
@end

@interface OLCallStats : NSObject
@property (nonatomic, readonly, copy) NSString *codec;
@property (nonatomic, readonly) NSInteger clockRate;
@property (nonatomic, readonly, copy) NSString *remoteAddress;
@property (nonatomic, readonly) NSInteger txPackets;
@property (nonatomic, readonly) NSInteger rxPackets;
@property (nonatomic, readonly) NSInteger rxLost;
@property (nonatomic, readonly) NSInteger rxJitterMsec;
@property (nonatomic, readonly) NSInteger rttMsec;
/// Conference-bridge signal levels, 0–255: remote party and what we transmit.
@property (nonatomic, readonly) NSInteger rxLevel;
@property (nonatomic, readonly) NSInteger txLevel;
@end

typedef void (^OLEventHandler)(OLEvent *event);
typedef void (^OLLogHandler)(NSString *line);
typedef void (^OLCompletion)(NSError *_Nullable error);

@interface OLEngine : NSObject

- (instancetype)initWithEventHandler:(OLEventHandler)eventHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Installed before `start`. `level` 0 disables logging; 4+ includes SIP traces.
- (void)setLogHandler:(nullable OLLogHandler)handler level:(NSInteger)level;

- (void)start:(OLEngineConfig *)config completion:(OLCompletion)completion;
/// Hangs up, unregisters, releases media, joins the SIP thread.
- (void)shutdown:(void (^)(void))completion;

- (void)addAccount:(OLAccountSpec *)spec registerNow:(BOOL)registerNow completion:(OLCompletion)completion;
- (void)removeAccount:(NSString *)accountID completion:(OLCompletion)completion;
- (void)setRegistered:(BOOL)registered account:(NSString *)accountID completion:(OLCompletion)completion;

/// On success `handle` is the engine's stable identifier for the new call.
- (void)makeCallTo:(NSString *)uri
           account:(NSString *)accountID
        completion:(void (^)(NSString *_Nullable handle, NSError *_Nullable error))completion;
- (void)sendRinging:(NSString *)callHandle completion:(OLCompletion)completion;
- (void)answer:(NSString *)callHandle completion:(OLCompletion)completion;
/// `statusCode` 0 lets the engine pick the response appropriate to the state.
- (void)hangup:(NSString *)callHandle statusCode:(NSInteger)statusCode completion:(OLCompletion)completion;
- (void)setHold:(BOOL)hold call:(NSString *)callHandle completion:(OLCompletion)completion;
- (void)setMuted:(BOOL)muted call:(NSString *)callHandle completion:(OLCompletion)completion;
- (void)sendDTMF:(NSString *)digits
          method:(OLDTMFMethod)method
            call:(NSString *)callHandle
      completion:(OLCompletion)completion;
- (void)transfer:(NSString *)callHandle to:(NSString *)uri completion:(OLCompletion)completion;
- (void)statsForCall:(NSString *)callHandle
          completion:(void (^)(OLCallStats *_Nullable stats))completion;

- (void)listAudioDevices:(void (^)(NSArray<OLAudioDeviceInfo *> *devices))completion;
/// nil selects the system default. Names survive replugging, indices do not.
- (void)selectAudioInput:(nullable NSString *)input
                  output:(nullable NSString *)output
              completion:(OLCompletion)completion;
/// Call when Core Audio reports a device list or default-device change.
- (void)audioHardwareChanged;

/// Ordered "PCMU/8000/1"-style identifiers; everything else is disabled.
- (void)setCodecOrder:(NSArray<NSString *> *)codecIDs completion:(OLCompletion)completion;
- (void)availableCodecs:(void (^)(NSArray<NSString *> *codecIDs))completion;
- (void)setSTUNServers:(NSArray<NSString *> *)servers;

/// Call after a network path change or wake from sleep.
- (void)handleNetworkChange;

@end

NS_ASSUME_NONNULL_END
