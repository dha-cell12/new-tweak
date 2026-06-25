// =============================================================================
// TLinkJSHelperServer.mm  (Phase 1-6 - helper daemon brain)
// -----------------------------------------------------------------------------
// Authoritative runtime state machine + session manager living inside
// tlinkauto-jsd. See TLinkJSHelperServer.h for the design contract.
//
// Lanes:
//   _controlQueue  : serial, drains IPC messages. NEVER blocks on JS.
//   _jsQueue       : serial, owns TLinkJSRuntimeCore. Runs exactly one session.
//
// Native RPC OUT (JS -> SpringBoard):
//   TLinkHelperBridgeAdapter (below, conforms to TLinkJSNativeBridge) is called
//   on the JS thread. It registers a pending request keyed by requestId, emits
//   a nativeRequest event on the channel, then blocks the JS thread on an
//   NSCondition until either nativeResponse arrives (delivered on _controlQueue)
//   or deadlineMs / cancellation fires.
// =============================================================================

#import "TLinkJSHelperServer.h"
#import "TLinkJSIPCChannel.h"
#import "TLinkJSProtocol.h"
#import "TLinkJSRuntimeCore.h"
#import "TLinkJSNativeBridge.h"

#include <atomic>

// ---------------------------------------------------------------------------
// Pending native RPC bookkeeping (one per in-flight device.* call).
// ---------------------------------------------------------------------------
@interface TLinkJSPendingNative : NSObject
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, assign) BOOL responded;
@property (nonatomic, strong, nullable) NSDictionary *responsePayload;
@property (nonatomic, copy, nullable) NSString *transportError;
@end
@implementation TLinkJSPendingNative @end

// ---------------------------------------------------------------------------
// Helper-side native bridge: turns a core native call into an IPC round-trip.
// ---------------------------------------------------------------------------
@interface TLinkHelperBridgeAdapter : NSObject <TLinkJSNativeBridge>
@property (nonatomic, weak) TLinkJSHelperServer *server;
@end

@interface TLinkJSHelperServer () <TLinkJSRuntimeCoreDelegate>
- (NSDictionary *)_awaitNativeResultForCode:(NSInteger)code
                                    payload:(NSString *)payload
                                 deadlineMs:(NSInteger)deadlineMs
                                isCancelled:(BOOL (^)(void))isCancelled
                             transportError:(NSString **)transportError;
@end

@implementation TLinkJSHelperServer {
    TLinkJSIPCChannel  *_channel;
    dispatch_queue_t    _controlQueue;
    dispatch_queue_t    _jsQueue;

    TLinkJSRuntimeCore *_core;
    TLinkHelperBridgeAdapter *_bridge;

    // ---- authoritative state (mutated only on _controlQueue) ----
    TLinkJSState        _state;
    uint64_t            _stateSequence;
    NSString           *_activeSessionId;   // nil when idle
    BOOL                _handshaked;

    // ---- console buffer (fetchLogs) ----
    NSMutableArray<TLinkJSConsoleEntry *> *_logBuffer;
    uint64_t            _logDropped;
    NSLock             *_logLock;

    // ---- native RPC out ----
    NSMutableDictionary<NSString *, TLinkJSPendingNative *> *_pendingNative;
    NSLock             *_pendingLock;
    std::atomic<uint64_t> _requestCounter;
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _helperInstanceId = [[NSUUID UUID] UUIDString];
    _controlQueue = dispatch_queue_create("com.tlinkauto.jsd.control", DISPATCH_QUEUE_SERIAL);
    _jsQueue      = dispatch_queue_create("com.tlinkauto.jsd.js", DISPATCH_QUEUE_SERIAL);

    _state = TLinkJSStateIdle;
    _stateSequence = 0;
    _handshaked = NO;

    _logBuffer = [NSMutableArray array];
    _logDropped = 0;
    _logLock = [[NSLock alloc] init];

    _pendingNative = [NSMutableDictionary dictionary];
    _pendingLock = [[NSLock alloc] init];
    _requestCounter.store(0);

    _bridge = [[TLinkHelperBridgeAdapter alloc] init];
    _bridge.server = self;

    _core = [[TLinkJSRuntimeCore alloc] init];
    _core.nativeBridge = _bridge;
    _core.delegate = self;

    return self;
}

- (void)attachChannel:(TLinkJSIPCChannel *)channel {
    dispatch_async(_controlQueue, ^{
        if (self->_channel) {
            [self->_channel close];
        }
        self->_channel = channel;
        self->_handshaked = NO;

        __weak typeof(self) weakSelf = self;
        channel.onMessage = ^(NSDictionary *message) {
            // onMessage already arrives on the channel's serial delivery queue,
            // but we re-hop to _controlQueue so ALL state lives on one lane.
            dispatch_async(self->_controlQueue, ^{
                [weakSelf _handleMessage:message];
            });
        };
        channel.onDisconnect = ^{
            dispatch_async(self->_controlQueue, ^{
                [weakSelf _handleDisconnect];
            });
        };
    });
}

#pragma mark - Inbound dispatch (control lane)

- (void)_handleMessage:(NSDictionary *)message {
    NSString *type = message[kTLinkJSKeyType];

    // nativeResponse is a command but completes an outstanding RPC; route it
    // first so a busy JS lane is unblocked even mid-session.
    NSString *command = message[kTLinkJSKeyCommand];
    if ([type isEqualToString:kTLinkJSTypeCommand] &&
        [command isEqualToString:kTLinkJSCommandNativeResponse]) {
        [self _handleNativeResponse:message];
        return;
    }

    if (![type isEqualToString:kTLinkJSTypeCommand]) {
        return; // helper only consumes commands
    }

    // Handshake gate: everything except handshake is rejected until negotiated.
    if (!_handshaked && ![command isEqualToString:kTLinkJSCommandHandshake]) {
        [self _sendResponseTo:message ok:NO error:kTLinkJSErrInvalidEnvelope
                      message:@"handshake required" payload:nil];
        return;
    }

    if ([command isEqualToString:kTLinkJSCommandHandshake]) {
        [self _handleHandshake:message];
    } else if ([command isEqualToString:kTLinkJSCommandStart]) {
        [self _handleStart:message];
    } else if ([command isEqualToString:kTLinkJSCommandStop]) {
        [self _handleStop:message];
    } else if ([command isEqualToString:kTLinkJSCommandStatus]) {
        [self _handleStatus:message];
    } else if ([command isEqualToString:kTLinkJSCommandFetchLogs]) {
        [self _handleFetchLogs:message];
    } else {
        [self _sendResponseTo:message ok:NO error:kTLinkJSErrUnknownCommand
                      message:command ?: @"" payload:nil];
    }
}

- (void)_handleDisconnect {
    // SpringBoard went away. Abort any running session; it will be marked
    // crashed on the other side (helperInstanceId changes on our next launch).
    if (_state == TLinkJSStateRunning || _state == TLinkJSStateStarting) {
        [_core requestStop];
    }
    _channel = nil;
    _handshaked = NO;
    // Fail any pending native RPC so the JS thread unwinds promptly.
    [self _failAllPendingNative:kTLinkJSErrNativeCancelled];
}

#pragma mark - handshake

- (void)_handleHandshake:(NSDictionary *)message {
    NSInteger theirVersion = [message[kTLinkJSKeyProtocolVersion] integerValue];
    if (theirVersion != kTLinkJSProtocolVersion) {
        [self _sendResponseTo:message ok:NO error:kTLinkJSErrProtocolMismatch
                      message:[NSString stringWithFormat:@"helper=%ld peer=%ld",
                               (long)kTLinkJSProtocolVersion, (long)theirVersion]
                      payload:nil];
        return;
    }
    _handshaked = YES;
    NSDictionary *payload = @{
        @"protocolVersion": @(kTLinkJSProtocolVersion),
        @"helperInstanceId": _helperInstanceId,
        @"watchdogAvailable": @(_core.watchdogAvailable),
        @"runtimeLocation": [_bridge runtimeLocation],
    };
    [self _sendResponseTo:message ok:YES error:nil message:nil payload:payload];
}

#pragma mark - start / stop / status

- (void)_handleStart:(NSDictionary *)message {
    // One active session only - if busy, reject without enqueueing (plan.md).
    if (_state == TLinkJSStateStarting ||
        _state == TLinkJSStateRunning ||
        _state == TLinkJSStateStopping) {
        [self _sendResponseTo:message ok:NO error:kTLinkJSErrHelperBusy
                      message:@"a session is already active" payload:nil];
        return;
    }

    NSDictionary *payload = message[kTLinkJSKeyPayload];
    NSString *scriptPath = payload[kTLinkJSStartKeyScriptPath];
    NSString *bundlePath = payload[kTLinkJSStartKeyBundlePath];
    NSDictionary *manifest = payload[kTLinkJSStartKeyManifest];

    NSError *readErr = nil;
    NSString *source = nil;
    if (scriptPath.length) {
        source = [NSString stringWithContentsOfFile:scriptPath
                                           encoding:NSUTF8StringEncoding
                                              error:&readErr];
    }
    if (!source) {
        [self _sendResponseTo:message ok:NO error:kTLinkJSErrBundleInvalid
                      message:readErr.localizedDescription ?: @"script unreadable"
                      payload:nil];
        return;
    }

    // New session identity. We accept the caller's sessionId if provided, else
    // mint one; either way it is tied to this helperInstanceId.
    NSString *sessionId = message[kTLinkJSKeySessionId];
    if (!sessionId.length) sessionId = [[NSUUID UUID] UUIDString];
    _activeSessionId = sessionId;

    [self _transitionTo:TLinkJSStateStarting];

    // Accept immediately; the actual run is async on the JS lane.
    NSDictionary *accepted = @{ @"accepted": @YES, kTLinkJSKeySessionId: sessionId };
    [self _sendResponseTo:message ok:YES error:nil message:nil payload:accepted];

    NSString *capturedSession = sessionId;
    dispatch_async(_jsQueue, ^{
        // Mark running just before evaluation begins.
        dispatch_async(self->_controlQueue, ^{
            if ([self->_activeSessionId isEqualToString:capturedSession]) {
                [self _transitionTo:TLinkJSStateRunning];
            }
        });

        NSError *evalErr = nil;
        BOOL ok = [self->_core evaluateScript:source
                                  scriptPath:scriptPath
                                  bundlePath:bundlePath
                                    manifest:manifest
                                       error:&evalErr];

        BOOL aborted = [self->_core isAborted];
        dispatch_async(self->_controlQueue, ^{
            if (![self->_activeSessionId isEqualToString:capturedSession]) {
                return; // superseded; ignore stale completion
            }
            NSString *outcome;
            TLinkJSState finalState;
            if (aborted) {
                outcome = kTLinkJSOutcomeCancelled; finalState = TLinkJSStateCancelled;
            } else if (ok) {
                outcome = kTLinkJSOutcomeCompleted; finalState = TLinkJSStateCompleted;
            } else {
                outcome = kTLinkJSOutcomeFailed;    finalState = TLinkJSStateFailed;
            }
            [self _transitionTo:finalState];
            [self _emitCompletedForSession:capturedSession
                                   outcome:outcome
                                     error:evalErr.localizedDescription];
            // Return to idle so the next start is accepted.
            self->_activeSessionId = nil;
            [self _transitionTo:TLinkJSStateIdle];
        });
    });
}

- (void)_handleStop:(NSDictionary *)message {
    NSString *sessionId = message[kTLinkJSKeySessionId];
    if (sessionId.length && ![sessionId isEqualToString:_activeSessionId]) {
        // Stale stop for a session that is no longer active - ack benignly.
        [self _sendResponseTo:message ok:YES error:nil
                      message:@"no matching active session" payload:nil];
        return;
    }
    if (_state == TLinkJSStateRunning || _state == TLinkJSStateStarting) {
        [self _transitionTo:TLinkJSStateStopping];
        // requestStop is safe from this (control) lane even while JS loops.
        [_core requestStop];
        // Unblock any in-flight native RPC so the JS thread can observe abort.
        [self _failAllPendingNative:kTLinkJSErrNativeCancelled];
    }
    [self _sendResponseTo:message ok:YES error:nil message:nil payload:nil];
}

- (void)_handleStatus:(NSDictionary *)message {
    NSDictionary *payload = @{
        kTLinkJSKeyState: TLinkJSStateToString(_state),
        kTLinkJSKeyStateSequence: @(_stateSequence),
        kTLinkJSKeyHelperInstanceId: _helperInstanceId,
        kTLinkJSKeySessionId: _activeSessionId ?: @"",
    };
    [self _sendResponseTo:message ok:YES error:nil message:nil payload:payload];
}

#pragma mark - fetchLogs

- (void)_handleFetchLogs:(NSDictionary *)message {
    NSDictionary *payload = message[kTLinkJSKeyPayload];
    uint64_t after = (uint64_t)[payload[kTLinkJSLogsKeyAfterSequence] unsignedLongLongValue];
    NSInteger maxEntries = [payload[kTLinkJSLogsKeyMaxEntries] integerValue];
    if (maxEntries <= 0) maxEntries = 500;

    NSMutableArray *out = [NSMutableArray array];
    uint64_t dropped = 0;
    [_logLock lock];
    dropped = _logDropped;
    for (TLinkJSConsoleEntry *e in _logBuffer) {
        if (e.sequence > after) {
            [out addObject:@{
                kTLinkJSLogEntryKeySequence: @(e.sequence),
                kTLinkJSLogEntryKeyLevel: e.level ?: @"log",
                kTLinkJSLogEntryKeyMessage: e.message ?: @"",
                kTLinkJSLogEntryKeyTimestamp: @(e.timestamp),
            }];
            if ((NSInteger)out.count >= maxEntries) break;
        }
    }
    [_logLock unlock];

    [self _sendResponseTo:message ok:YES error:nil message:nil payload:@{
        kTLinkJSLogsKeyEntries: out,
        kTLinkJSLogsKeyDroppedCount: @(dropped),
    }];
}

#pragma mark - native RPC out (called from JS lane via the bridge)

- (NSDictionary *)_awaitNativeResultForCode:(NSInteger)code
                                    payload:(NSString *)payload
                                 deadlineMs:(NSInteger)deadlineMs
                                isCancelled:(BOOL (^)(void))isCancelled
                             transportError:(NSString **)transportError {
    if (deadlineMs <= 0) deadlineMs = kTLinkJSDefaultNativeDeadlineMs;

    NSString *requestId = [NSString stringWithFormat:@"%@-%llu",
                           _helperInstanceId,
                           (unsigned long long)_requestCounter.fetch_add(1) + 1];

    TLinkJSPendingNative *pending = [[TLinkJSPendingNative alloc] init];
    pending.condition = [[NSCondition alloc] init];

    [_pendingLock lock];
    _pendingNative[requestId] = pending;
    [_pendingLock unlock];

    // Snapshot identity for the event so SpringBoard can drop stale requests.
    NSString *sessionId = _activeSessionId;
    NSDictionary *event = @{
        kTLinkJSKeyType: kTLinkJSTypeEvent,
        kTLinkJSKeyEvent: kTLinkJSEventNativeRequest,
        kTLinkJSKeyProtocolVersion: @(kTLinkJSProtocolVersion),
        kTLinkJSKeyHelperInstanceId: _helperInstanceId,
        kTLinkJSKeySessionId: sessionId ?: @"",
        kTLinkJSKeyRequestId: requestId,
        kTLinkJSKeyDeadlineMs: @(deadlineMs),
        kTLinkJSKeyPayload: @{
            kTLinkJSNativeKeyTaskCode: @(code),
            kTLinkJSNativeKeyTaskPayload: payload ?: @"",
        },
    };
    // Send on the control lane; we are on the JS lane right now.
    TLinkJSIPCChannel *ch = _channel;
    if (!ch || ![ch sendMessage:event]) {
        [self _removePending:requestId];
        if (transportError) *transportError = kTLinkJSErrNativeCancelled;
        return nil;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)deadlineMs / 1000.0];
    NSDictionary *result = nil;
    NSString *txErr = nil;

    [pending.condition lock];
    while (!pending.responded) {
        if (isCancelled && isCancelled()) { txErr = kTLinkJSErrNativeCancelled; break; }
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
            txErr = kTLinkJSErrNativeTimeout; break;
        }
        // Wake periodically to re-check cancellation.
        [pending.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (pending.responded) {
        result = pending.responsePayload;
        txErr = pending.transportError;
    }
    [pending.condition unlock];

    [self _removePending:requestId];
    if (transportError) *transportError = txErr;
    return result;
}

- (void)_handleNativeResponse:(NSDictionary *)message {
    NSString *requestId = message[kTLinkJSKeyRequestId];
    if (!requestId.length) return;

    [_pendingLock lock];
    TLinkJSPendingNative *pending = _pendingNative[requestId];
    [_pendingLock unlock];
    if (!pending) return; // already timed out / cancelled - drop late response

    [pending.condition lock];
    if (!pending.responded) {
        pending.responded = YES;
        pending.responsePayload = message[kTLinkJSKeyPayload];
        pending.transportError = message[kTLinkJSKeyError];
        [pending.condition broadcast];
    }
    [pending.condition unlock];
}

- (void)_failAllPendingNative:(NSString *)error {
    [_pendingLock lock];
    NSArray *all = _pendingNative.allValues;
    [_pendingLock unlock];
    for (TLinkJSPendingNative *pending in all) {
        [pending.condition lock];
        if (!pending.responded) {
            pending.responded = YES;
            pending.transportError = error;
            [pending.condition broadcast];
        }
        [pending.condition unlock];
    }
}

- (void)_removePending:(NSString *)requestId {
    [_pendingLock lock];
    [_pendingNative removeObjectForKey:requestId];
    [_pendingLock unlock];
}

#pragma mark - state machine + emit

- (void)_transitionTo:(TLinkJSState)newState {
    _state = newState;
    _stateSequence++;
    NSString *sessionId = _activeSessionId;
    NSDictionary *event = @{
        kTLinkJSKeyType: kTLinkJSTypeEvent,
        kTLinkJSKeyEvent: kTLinkJSEventState,
        kTLinkJSKeyProtocolVersion: @(kTLinkJSProtocolVersion),
        kTLinkJSKeyHelperInstanceId: _helperInstanceId,
        kTLinkJSKeySessionId: sessionId ?: @"",
        kTLinkJSKeyState: TLinkJSStateToString(newState),
        kTLinkJSKeyStateSequence: @(_stateSequence),
    };
    [_channel sendMessage:event];
}

- (void)_emitCompletedForSession:(NSString *)sessionId
                         outcome:(NSString *)outcome
                           error:(nullable NSString *)errorMessage {
    NSMutableDictionary *event = [@{
        kTLinkJSKeyType: kTLinkJSTypeEvent,
        kTLinkJSKeyEvent: kTLinkJSEventCompleted,
        kTLinkJSKeyProtocolVersion: @(kTLinkJSProtocolVersion),
        kTLinkJSKeyHelperInstanceId: _helperInstanceId,
        kTLinkJSKeySessionId: sessionId ?: @"",
        kTLinkJSKeyStateSequence: @(_stateSequence),
        kTLinkJSKeyOutcome: outcome,
    } mutableCopy];
    if (errorMessage.length) event[kTLinkJSKeyErrorMessage] = errorMessage;
    [_channel sendMessage:event];
}

- (void)_sendResponseTo:(NSDictionary *)request
                     ok:(BOOL)ok
                  error:(nullable NSString *)error
                message:(nullable NSString *)message
                payload:(nullable NSDictionary *)payload {
    NSMutableDictionary *resp = [NSMutableDictionary dictionary];
    resp[kTLinkJSKeyType] = kTLinkJSTypeResponse;
    resp[kTLinkJSKeyProtocolVersion] = @(kTLinkJSProtocolVersion);
    resp[kTLinkJSKeyHelperInstanceId] = _helperInstanceId;
    resp[kTLinkJSKeyCommand] = request[kTLinkJSKeyCommand] ?: @"";
    if (request[kTLinkJSKeyRequestId]) resp[kTLinkJSKeyRequestId] = request[kTLinkJSKeyRequestId];
    if (request[kTLinkJSKeySessionId]) resp[kTLinkJSKeySessionId] = request[kTLinkJSKeySessionId];
    resp[kTLinkJSKeyOk] = @(ok);
    if (error) resp[kTLinkJSKeyError] = error;
    if (message) resp[kTLinkJSKeyErrorMessage] = message;
    if (payload) resp[kTLinkJSKeyPayload] = payload;
    [_channel sendMessage:resp];
}

#pragma mark - TLinkJSRuntimeCoreDelegate

- (void)runtimeCore:(TLinkJSRuntimeCore *)core didLogEntry:(TLinkJSConsoleEntry *)entry {
    static const NSUInteger kMaxBuffered = 2000;
    [_logLock lock];
    [_logBuffer addObject:entry];
    while (_logBuffer.count > kMaxBuffered) {
        [_logBuffer removeObjectAtIndex:0];
        _logDropped++;
    }
    [_logLock unlock];

    // Nudge SpringBoard to pull logs.
    NSDictionary *event = @{
        kTLinkJSKeyType: kTLinkJSTypeEvent,
        kTLinkJSKeyEvent: kTLinkJSEventLog,
        kTLinkJSKeyProtocolVersion: @(kTLinkJSProtocolVersion),
        kTLinkJSKeyHelperInstanceId: _helperInstanceId,
        kTLinkJSKeySessionId: _activeSessionId ?: @"",
        kTLinkJSKeyPayload: @{ kTLinkJSLogEntryKeySequence: @(entry.sequence) },
    };
    [_channel sendMessage:event];
}

- (void)runtimeCore:(TLinkJSRuntimeCore *)core didThrowExceptionMessage:(NSString *)message {
    TLinkJSConsoleEntry *e = [[TLinkJSConsoleEntry alloc] init];
    e.level = @"error";
    e.message = message ?: @"uncaught exception";
    e.timestamp = [[NSDate date] timeIntervalSince1970];
    [self runtimeCore:core didLogEntry:e];
}

@end

// ---------------------------------------------------------------------------
// TLinkHelperBridgeAdapter
// ---------------------------------------------------------------------------
@implementation TLinkHelperBridgeAdapter

- (NSString *)runtimeLocation { return @"helper-daemon"; }

- (TLinkJSNativeResult *)performTaskCode:(NSInteger)taskCode
                             taskPayload:(NSString *)taskPayload
                                 options:(TLinkJSNativeCallOptions *)options
                             isCancelled:(BOOL (^)(void))isCancelled {
    TLinkJSHelperServer *server = self.server;
    if (!server) return [TLinkJSNativeResult transportFailure:kTLinkJSErrNativeCancelled];

    NSString *txErr = nil;
    NSDictionary *payload = [server _awaitNativeResultForCode:taskCode
                                                      payload:taskPayload
                                                   deadlineMs:options.deadlineMs
                                                  isCancelled:isCancelled
                                               transportError:&txErr];
    if (txErr) {
        return [TLinkJSNativeResult transportFailure:txErr];
    }
    NSString *raw = payload[kTLinkJSNativeKeyResultRaw] ?: @"";
    NSArray *parts = [raw componentsSeparatedByString:@";;"];
    BOOL ok = (parts.count > 0 && [parts[0] isEqualToString:@"0"]);
    return [TLinkJSNativeResult resultWithOk:ok raw:raw parts:parts];
}

@end
