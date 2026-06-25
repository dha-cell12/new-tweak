#ifndef TLINK_INPROCESS_BRIDGE_ADAPTER_H
#define TLINK_INPROCESS_BRIDGE_ADAPTER_H

// =============================================================================
// TLinkInProcessBridgeAdapter.h  (Phase 0 - In-process adapter)
// -----------------------------------------------------------------------------
// The concrete id<TLinkJSNativeBridge> used while the runtime core still lives
// inside SpringBoard (current prototype / Phase 3 fallback). It calls the
// existing C entry point processTask() directly, reproducing the exact wire
// format TLinkautoDeviceBridge already uses:
//
//     request : "<taskCode>;;<taskPayload>"
//     response: status-prefixed string, parts split on ";;"
//
// This is the ONLY file in jshelper/ that is allowed to depend on Task.h /
// processTask(). Keeping that dependency isolated here is what lets
// TLinkJSRuntimeCore stay portable: the helper daemon swaps this adapter for an
// IPC-backed one (TLinkHelperBridgeAdapter) without the core changing at all.
//
// A deadline is enforced by running processTask() on a worker queue and waiting
// with a timeout, so a single misbehaving native task cannot wedge the JS
// serial queue forever (plan.md: "Native RPC phai co timeout/cancellation").
// =============================================================================

#import <Foundation/Foundation.h>
#import "TLinkJSNativeBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface TLinkInProcessBridgeAdapter : NSObject <TLinkJSNativeBridge>
@end

NS_ASSUME_NONNULL_END

#endif /* TLINK_INPROCESS_BRIDGE_ADAPTER_H */
