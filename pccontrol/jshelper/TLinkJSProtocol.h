#ifndef TLINK_JS_PROTOCOL_H
#define TLINK_JS_PROTOCOL_H

// =============================================================================
// TLinkJSProtocol.h  (Phase 0 - Protocol Spec)
// -----------------------------------------------------------------------------
// Single source of truth for the wire contract between:
//
//     App / TCP client  ->  tlinkautod (router)  ->  SpringBoard (ScriptPlayer)
//                                                          <->  tlinkauto-jsd (helper)
//
// Design rules encoded here (from plan.md "Cac Bo Sung Bat Buoc"):
//   * Every message carries a versioned envelope: protocolVersion,
//     helperInstanceId, sessionId, requestId.
//   * helperInstanceId is created once when the helper process starts. After a
//     helper restart it changes, so SpringBoard can mark the old session as
//     "crashed" and drop late events/responses.
//   * The helper owns the authoritative runtime state machine. ScriptPlayer
//     only mirrors state for UI/routing. Every state event carries a
//     monotonically increasing stateSequence; SpringBoard accepts only newer.
//   * Native RPC requests carry their own requestId + deadlineMs so the helper
//     never waits forever and SpringBoard can drop stale responses.
//
// This header is pure declarations (NSString constants + enums) so it can be
// imported by both the in-SpringBoard side and the standalone helper without
// pulling in JavaScriptCore, UIKit or SpringBoard private headers.
// =============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// -----------------------------------------------------------------------------
// Versioning
// -----------------------------------------------------------------------------

/// Bump whenever the envelope shape or any command/event semantics change in a
/// non-backward-compatible way. handshake compares this on both ends.
static const NSInteger kTLinkJSProtocolVersion = 1;

// -----------------------------------------------------------------------------
// Envelope keys (every message is a flat JSON object with these keys)
// -----------------------------------------------------------------------------

static NSString *const kTLinkJSKeyProtocolVersion  = @"protocolVersion";
static NSString *const kTLinkJSKeyType             = @"type";            // "command" | "response" | "event"
static NSString *const kTLinkJSKeyCommand          = @"command";         // see TLinkJSCommand* below
static NSString *const kTLinkJSKeyEvent            = @"event";           // see TLinkJSEvent* below
static NSString *const kTLinkJSKeyHelperInstanceId = @"helperInstanceId";
static NSString *const kTLinkJSKeySessionId        = @"sessionId";
static NSString *const kTLinkJSKeyRequestId        = @"requestId";
static NSString *const kTLinkJSKeyDeadlineMs       = @"deadlineMs";
static NSString *const kTLinkJSKeyStateSequence    = @"stateSequence";
static NSString *const kTLinkJSKeyPayload          = @"payload";         // command/response body (object)
static NSString *const kTLinkJSKeyOk               = @"ok";              // response success flag (bool)
static NSString *const kTLinkJSKeyError            = @"error";           // error code string (see below)
static NSString *const kTLinkJSKeyErrorMessage     = @"errorMessage";    // human readable detail
static NSString *const kTLinkJSKeyState            = @"state";           // see TLinkJSState* below
static NSString *const kTLinkJSKeyOutcome          = @"outcome";         // see TLinkJSOutcome* below

// Message "type" discriminator values.
static NSString *const kTLinkJSTypeCommand  = @"command";
static NSString *const kTLinkJSTypeResponse = @"response";
static NSString *const kTLinkJSTypeEvent    = @"event";

// -----------------------------------------------------------------------------
// Commands  (router/ScriptPlayer -> helper, except nativeResponse)
// -----------------------------------------------------------------------------

/// Capability/version negotiation. MUST be the first command after connect.
static NSString *const kTLinkJSCommandHandshake     = @"handshake";
/// Start a script session. Returns "accepted" immediately (does not wait for
/// the script to finish). One active session only; if busy -> helper_busy.
static NSString *const kTLinkJSCommandStart         = @"start";
/// Cooperative stop of a session. Must be honored by the control queue even
/// while the JS queue is stuck in a loop.
static NSString *const kTLinkJSCommandStop          = @"stop";
/// Lightweight current-state poll.
static NSString *const kTLinkJSCommandStatus        = @"status";
/// Pull structured console logs (afterSequence, maxEntries) -> entries+droppedCount.
static NSString *const kTLinkJSCommandFetchLogs     = @"fetchLogs";
/// Reply to a nativeRequest event. This is the ONLY message that flows
/// SpringBoard -> helper carrying a native RPC result.
static NSString *const kTLinkJSCommandNativeResponse = @"nativeResponse";

// -----------------------------------------------------------------------------
// Events  (helper -> SpringBoard/router)
// -----------------------------------------------------------------------------

/// State machine transition. Carries kTLinkJSKeyState + kTLinkJSKeyStateSequence.
static NSString *const kTLinkJSEventState        = @"state";
/// A console log line was produced (or buffered). Used to wake fetchLogs.
static NSString *const kTLinkJSEventLog          = @"log";
/// Helper needs SpringBoard to perform a native task. Carries requestId +
/// deadlineMs; SpringBoard must reply with nativeResponse before the deadline.
static NSString *const kTLinkJSEventNativeRequest = @"nativeRequest";
/// Terminal result of a session (carries kTLinkJSKeyOutcome).
static NSString *const kTLinkJSEventCompleted    = @"completed";

// -----------------------------------------------------------------------------
// Runtime state machine (authoritative on the helper)
// -----------------------------------------------------------------------------
//
//   idle -> starting -> running -> stopping -> (completed|cancelled|failed)
//
// "crashed" is NOT emitted by the helper; it is inferred by SpringBoard when
// the helper disconnects or its helperInstanceId changes.
// -----------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, TLinkJSState) {
    TLinkJSStateIdle = 0,
    TLinkJSStateStarting,
    TLinkJSStateRunning,
    TLinkJSStateStopping,
    TLinkJSStateCompleted,
    TLinkJSStateCancelled,
    TLinkJSStateFailed,
    TLinkJSStateCrashed,   // SpringBoard-inferred only
};

static inline NSString *TLinkJSStateToString(TLinkJSState state) {
    switch (state) {
        case TLinkJSStateIdle:      return @"idle";
        case TLinkJSStateStarting:  return @"starting";
        case TLinkJSStateRunning:   return @"running";
        case TLinkJSStateStopping:  return @"stopping";
        case TLinkJSStateCompleted: return @"completed";
        case TLinkJSStateCancelled: return @"cancelled";
        case TLinkJSStateFailed:    return @"failed";
        case TLinkJSStateCrashed:   return @"crashed";
    }
    return @"idle";
}

static inline TLinkJSState TLinkJSStateFromString(NSString *_Nullable s) {
    if ([s isEqualToString:@"starting"])  return TLinkJSStateStarting;
    if ([s isEqualToString:@"running"])   return TLinkJSStateRunning;
    if ([s isEqualToString:@"stopping"])  return TLinkJSStateStopping;
    if ([s isEqualToString:@"completed"]) return TLinkJSStateCompleted;
    if ([s isEqualToString:@"cancelled"]) return TLinkJSStateCancelled;
    if ([s isEqualToString:@"failed"])    return TLinkJSStateFailed;
    if ([s isEqualToString:@"crashed"])   return TLinkJSStateCrashed;
    return TLinkJSStateIdle;
}

// Terminal outcome reported with kTLinkJSEventCompleted.
static NSString *const kTLinkJSOutcomeCompleted = @"completed";
static NSString *const kTLinkJSOutcomeCancelled = @"cancelled";
static NSString *const kTLinkJSOutcomeFailed    = @"failed";

// -----------------------------------------------------------------------------
// Error codes (string values in kTLinkJSKeyError)
// -----------------------------------------------------------------------------
// Stable identifiers so the router/app can branch without parsing messages.

static NSString *const kTLinkJSErrProtocolMismatch       = @"protocol_mismatch";
static NSString *const kTLinkJSErrHelperBusy             = @"helper_busy";
static NSString *const kTLinkJSErrUnknownCommand         = @"unknown_command";
static NSString *const kTLinkJSErrInvalidEnvelope        = @"invalid_envelope";
static NSString *const kTLinkJSErrSessionMismatch        = @"session_mismatch";
static NSString *const kTLinkJSErrHelperInstanceMismatch = @"helper_instance_mismatch";
static NSString *const kTLinkJSErrNativeTimeout          = @"native_timeout";
static NSString *const kTLinkJSErrNativeCancelled        = @"native_cancelled";
static NSString *const kTLinkJSErrBundleInvalid          = @"bundle_invalid";
/// Production: returned instead of silently falling back to in-process JS.
static NSString *const kTLinkJSErrRuntimeUnavailable     = @"javascript_runtime_unavailable";

// -----------------------------------------------------------------------------
// start command payload keys
// -----------------------------------------------------------------------------

static NSString *const kTLinkJSStartKeyScriptPath = @"scriptPath";
static NSString *const kTLinkJSStartKeyBundlePath = @"bundlePath";
static NSString *const kTLinkJSStartKeyEntry      = @"entry";       // bundle-relative entry file
static NSString *const kTLinkJSStartKeyManifest   = @"manifest";    // object

// -----------------------------------------------------------------------------
// nativeRequest / nativeResponse payload keys
// -----------------------------------------------------------------------------

static NSString *const kTLinkJSNativeKeyTaskCode   = @"taskCode";   // int (legacy processTask code)
static NSString *const kTLinkJSNativeKeyTaskPayload = @"taskPayload";// string (legacy ";;" wire payload)
static NSString *const kTLinkJSNativeKeyResultRaw  = @"raw";        // raw processTask response string
static NSString *const kTLinkJSNativeKeyFilePath   = @"filePath";   // for large payloads (Phase 4)
static NSString *const kTLinkJSNativeKeyFileToken  = @"fileToken";
static NSString *const kTLinkJSNativeKeyFileSize   = @"size";
static NSString *const kTLinkJSNativeKeyExpiresAt  = @"expiresAt";

// -----------------------------------------------------------------------------
// fetchLogs payload keys
// -----------------------------------------------------------------------------

static NSString *const kTLinkJSLogsKeyAfterSequence = @"afterSequence";
static NSString *const kTLinkJSLogsKeyMaxEntries    = @"maxEntries";
static NSString *const kTLinkJSLogsKeyEntries       = @"entries";
static NSString *const kTLinkJSLogsKeyDroppedCount  = @"droppedCount";
static NSString *const kTLinkJSLogEntryKeySequence  = @"sequence";
static NSString *const kTLinkJSLogEntryKeyLevel     = @"level";
static NSString *const kTLinkJSLogEntryKeyMessage   = @"message";
static NSString *const kTLinkJSLogEntryKeyTimestamp = @"timestamp";

// -----------------------------------------------------------------------------
// Default timing budgets (milliseconds)
// -----------------------------------------------------------------------------

/// Cooperative stop window before SpringBoard escalates to SIGTERM/SIGKILL.
static const NSInteger kTLinkJSStopDeadlineMs        = 2000;
/// Default deadline for a single native RPC if the caller does not specify one.
static const NSInteger kTLinkJSDefaultNativeDeadlineMs = 15000;
/// Longer default for heavy native ops (OCR / shell / screenshot).
static const NSInteger kTLinkJSHeavyNativeDeadlineMs = 60000;

NS_ASSUME_NONNULL_END

#endif /* TLINK_JS_PROTOCOL_H */
