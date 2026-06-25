#ifndef TLINK_JS_IPC_CHANNEL_H
#define TLINK_JS_IPC_CHANNEL_H

// =============================================================================
// TLinkJSIPCChannel.h  (Phase 1 - IPC transport)
// -----------------------------------------------------------------------------
// A tiny length-prefixed JSON message channel over an AF_UNIX stream socket,
// usable identically on both ends:
//
//   * Helper (tlinkauto-jsd) binds + listens, accepts one SpringBoard client.
//   * SpringBoard connects as a client.
//
// Framing: each message is  [uint32 big-endian length][UTF-8 JSON bytes].
// Messages are the protocol envelopes defined in TLinkJSProtocol.h.
//
// Why a raw socket (vs CFMessagePort): a stream socket gives us a single fd we
// can poll() with a timeout on a dedicated read thread, makes disconnect
// detection trivial (EOF), and lets the control side stay responsive while the
// JS side is busy (the two run on independent queues per plan.md).
//
// Threading: the channel owns a background read loop. Decoded messages are
// delivered via `onMessage` on an internal serial queue. `sendMessage:` is
// thread-safe (serialized writes). `onDisconnect` fires once on EOF/error.
// =============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Fixed filesystem path for the helper's listening socket. Lives under the
/// app's writable container so both SpringBoard and the daemon can reach it.
static NSString *const kTLinkJSHelperSocketPath = @"/var/mobile/Library/TLinkauto/jsd.sock";

@interface TLinkJSIPCChannel : NSObject

/// Called for every fully-decoded inbound message (envelope dictionary).
@property (nonatomic, copy, nullable) void (^onMessage)(NSDictionary *message);
/// Called exactly once when the peer disconnects or a fatal I/O error occurs.
@property (nonatomic, copy, nullable) void (^onDisconnect)(void);

/// Wrap an already-connected/accepted socket fd and start the read loop.
- (instancetype)initWithSocketFD:(int)fd;

/// Encode + send one envelope. Returns NO if the socket is already closed.
- (BOOL)sendMessage:(NSDictionary *)message;

/// Stop the read loop and close the fd. Idempotent.
- (void)close;

// --- Convenience factories ------------------------------------------------

/// Helper side: create+bind+listen on kTLinkJSHelperSocketPath, block until one
/// client connects (or `timeoutMs` elapses), and return a channel for it.
/// Returns nil on timeout/error.
+ (nullable instancetype)acceptOnPath:(NSString *)path timeoutMs:(NSInteger)timeoutMs;

/// SpringBoard side: connect to a listening helper. Returns nil on error.
+ (nullable instancetype)connectToPath:(NSString *)path timeoutMs:(NSInteger)timeoutMs;

@end

NS_ASSUME_NONNULL_END

#endif /* TLINK_JS_IPC_CHANNEL_H */
