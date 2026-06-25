#ifndef TLINK_JS_HELPER_SERVER_H
#define TLINK_JS_HELPER_SERVER_H

// =============================================================================
// TLinkJSHelperServer.h  (Phase 1-6 - helper daemon brain)
// -----------------------------------------------------------------------------
// Runs INSIDE tlinkauto-jsd. Owns:
//   * the authoritative runtime state machine (idle/starting/running/...);
//   * helperInstanceId (a fresh UUID per process launch);
//   * the single active JS session (one at a time, no queue - plan.md);
//   * two independent execution lanes:
//       - control/IPC lane: the channel delivery queue (handshake, start, stop,
//         status, fetchLogs, nativeResponse). Never blocks on JS.
//       - JS serial queue: owns the TLinkJSRuntimeCore (JSVM/JSContext).
//   * native RPC OUT to SpringBoard: when JS calls device.*, the helper sends a
//     nativeRequest event (requestId + deadlineMs) and blocks the JS thread on
//     a condition until the matching nativeResponse arrives or the deadline
//     fires. The control lane stays free the whole time.
//
// The server is transport-agnostic: it is handed a connected TLinkJSIPCChannel.
// =============================================================================

#import <Foundation/Foundation.h>

@class TLinkJSIPCChannel;

NS_ASSUME_NONNULL_BEGIN

@interface TLinkJSHelperServer : NSObject

/// Stable identity for this helper process. Created once at init.
@property (nonatomic, readonly) NSString *helperInstanceId;

/// Bind the server to a freshly connected channel and send nothing until the
/// peer handshakes. Replaces any previous channel (old one is closed).
- (void)attachChannel:(TLinkJSIPCChannel *)channel;

@end

NS_ASSUME_NONNULL_END

#endif /* TLINK_JS_HELPER_SERVER_H */
