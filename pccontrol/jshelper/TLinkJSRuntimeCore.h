#ifndef TLINK_JS_RUNTIME_CORE_H
#define TLINK_JS_RUNTIME_CORE_H

// =============================================================================
// TLinkJSRuntimeCore.h  (Phase 0 - Core Extraction)
// -----------------------------------------------------------------------------
// The reusable JavaScript runtime, extracted from TLinkautoJSRuntime so it can
// run in EITHER place:
//   * in-process inside SpringBoard (current prototype), or
//   * inside the standalone tlinkauto-jsd helper (Phase 1+).
//
// Hard rule from plan.md ("Reuse runtime phai tach core khoi SpringBoard
// dependency"): this class owns ONLY
//       JSVM, JSContext, evaluate, watchdog, console, cancellation
// and reaches every native capability through id<TLinkJSNativeBridge>. It MUST
// NOT import ScriptPlayer, Task.xm, SpringBoard private APIs, or UIKit.
//
// Threading contract (plan.md "Helper phai co hai queue doc lap"):
//   * `evaluateScript...` is expected to be invoked from the JS serial queue.
//   * `requestStop` may be called from ANY thread (the control queue) at any
//     time, including while JS is in an infinite loop. It flips the abort flag
//     (consumed by the watchdog + interruptible sleep) and broadcasts the
//     sleep condition. It never touches the JSContext directly.
// =============================================================================

#import <Foundation/Foundation.h>
#import "TLinkJSNativeBridge.h"

NS_ASSUME_NONNULL_BEGIN

@class TLinkJSRuntimeCore;

// Structured console entry surfaced to the host (helper buffers these and
// serves them via fetchLogs; in-process host can write them to a file).
@interface TLinkJSConsoleEntry : NSObject
@property (nonatomic, assign) uint64_t sequence;
@property (nonatomic, copy)   NSString *level;
@property (nonatomic, copy)   NSString *message;
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

// Host hooks. The core stays UI-agnostic; the host decides what to do with
// logs and lifecycle notifications. All callbacks may arrive on internal
// queues, so the host must be thread-safe.
@protocol TLinkJSRuntimeCoreDelegate <NSObject>
@optional
/// A console.* line was produced. `entry.sequence` is monotonic per run.
- (void)runtimeCore:(TLinkJSRuntimeCore *)core didLogEntry:(TLinkJSConsoleEntry *)entry;
/// An uncaught JS exception occurred (already set on the context).
- (void)runtimeCore:(TLinkJSRuntimeCore *)core didThrowExceptionMessage:(NSString *)message;
@end

@interface TLinkJSRuntimeCore : NSObject

/// The native capability provider. Required before evaluating any script that
/// touches `device.*`.
@property (nonatomic, strong) id<TLinkJSNativeBridge> nativeBridge;
@property (nonatomic, weak, nullable) id<TLinkJSRuntimeCoreDelegate> delegate;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly, copy) NSString *runId;
/// YES when the private watchdog API was detected and self-tested OK.
@property (nonatomic, readonly) BOOL watchdogAvailable;

- (instancetype)init;

/// Evaluate a script. Blocks the calling (JS serial) queue until the script
/// returns, throws, or is aborted. Returns NO and fills `error` on failure.
/// `manifest` is exposed to JS as the global `manifest`; `bundlePath` scopes
/// module resolution and file storage.
- (BOOL)evaluateScript:(NSString *)source
            scriptPath:(nullable NSString *)scriptPath
            bundlePath:(nullable NSString *)bundlePath
              manifest:(nullable NSDictionary *)manifest
                 error:(NSError *_Nullable *_Nullable)error;

/// Cooperative + hard (watchdog) cancellation. Safe from any thread.
- (void)requestStop;

/// True after requestStop until the run unwinds. Adapters poll this to abort
/// in-flight native RPC.
- (BOOL)isAborted;

/// runtimeInfo() backing data, merged with bridge.runtimeLocation by the host.
- (NSDictionary *)runtimeInfoSnapshot;

@end

NS_ASSUME_NONNULL_END

#endif /* TLINK_JS_RUNTIME_CORE_H */
