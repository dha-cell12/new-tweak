#ifndef TLINK_JS_NATIVE_BRIDGE_H
#define TLINK_JS_NATIVE_BRIDGE_H

// =============================================================================
// TLinkJSNativeBridge.h  (Phase 0 - Bridge Interface)
// -----------------------------------------------------------------------------
// The seam that lets TLinkJSRuntimeCore stay free of SpringBoard / processTask /
// UIKit dependencies. The core asks "perform this native task" through this
// protocol; the concrete adapter decides HOW:
//
//   * TLinkInProcessBridgeAdapter  -> calls processTask() directly (current
//                                     in-process prototype, Phase 3).
//   * TLinkHelperBridgeAdapter     -> sends a nativeRequest over IPC to
//                                     SpringBoard and waits for nativeResponse,
//                                     respecting deadlineMs + cancellation
//                                     (Phase 3).
//
// The legacy wire format (numeric task code + ";;"-delimited payload string,
// already used by TLinkautoDeviceBridge -> processTask) is preserved so the JS
// `device.*` API and the SpringBoard Task.xm handlers do not have to change in
// Phase 0-3. Phase 4 layers file-token payloads on top.
// =============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Result of a single native task. Mirrors the dictionary shape the existing
// runtime already returns ({ ok, raw, parts }) plus bridge-level metadata so
// callers can distinguish a task-level failure from a transport-level one.
@interface TLinkJSNativeResult : NSObject
@property (nonatomic, assign) BOOL ok;                 // task succeeded (status "0")
@property (nonatomic, copy)   NSString *raw;           // raw processTask response
@property (nonatomic, copy)   NSArray<NSString *> *parts; // raw split on ";;"
@property (nonatomic, copy, nullable) NSString *transportError; // non-nil => RPC failed
                                                                // (timeout/cancelled/disconnect)
+ (instancetype)resultWithOk:(BOOL)ok raw:(NSString *)raw parts:(NSArray<NSString *> *)parts;
+ (instancetype)transportFailure:(NSString *)error; // e.g. kTLinkJSErrNativeTimeout
@end

// Per-call execution constraints. Created by the core for each native call so
// no native RPC can block forever and cancellation propagates.
@interface TLinkJSNativeCallOptions : NSObject
@property (nonatomic, assign) NSInteger deadlineMs;    // 0 => adapter default
@property (nonatomic, copy, nullable) NSString *sessionId;
@property (nonatomic, copy, nullable) NSString *helperInstanceId;
+ (instancetype)optionsWithDeadlineMs:(NSInteger)deadlineMs;
@end

// The abstraction the core depends on. Adapters MUST:
//   * return promptly when options.deadlineMs elapses (transportFailure:native_timeout)
//   * observe the cancellation block and abort in-flight work
//   * never retain a reference to JavaScriptCore objects
@protocol TLinkJSNativeBridge <NSObject>

/// Perform a legacy native task synchronously from the JS serial queue.
/// `isCancelled` is polled cooperatively by adapters that can be interrupted.
- (TLinkJSNativeResult *)performTaskCode:(NSInteger)taskCode
                             taskPayload:(NSString *)taskPayload
                                 options:(TLinkJSNativeCallOptions *)options
                             isCancelled:(BOOL (^_Nullable)(void))isCancelled;

/// Human-readable adapter identity reported via runtimeInfo().runtimeLocation.
/// e.g. "in-process-prototype" or "helper-daemon".
- (NSString *)runtimeLocation;

@end

NS_ASSUME_NONNULL_END

#endif /* TLINK_JS_NATIVE_BRIDGE_H */
