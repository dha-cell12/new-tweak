// =============================================================================
// TLinkInProcessBridgeAdapter.mm  (Phase 0 - In-process adapter)
// -----------------------------------------------------------------------------
// See TLinkInProcessBridgeAdapter.h. Bridges TLinkJSRuntimeCore to the legacy
// in-SpringBoard processTask() C function.
//
// Wire format reproduced from the existing TLinkautoDeviceBridge:
//   * Outgoing buffer is the UTF-8 of "<taskCode>;;<taskPayload>".
//   * processTask() writes its reply into a CFWriteStream; we capture it via a
//     bound CFReadStream pair and read the whole reply back.
//   * The reply is a string; status is the first ";;"-delimited part ("0" = ok).
//
// Timeout / cancellation:
//   * processTask() runs on a dedicated concurrent queue.
//   * The JS serial queue (our caller) waits on a semaphore with deadlineMs.
//   * On timeout we return transportFailure:native_timeout and let the worker
//     finish in the background (its result is discarded). isCancelled is polled
//     in the wait loop so requestStop() aborts the wait promptly.
// =============================================================================

#import "TLinkInProcessBridgeAdapter.h"
#import "TLinkJSProtocol.h"

#import <Foundation/Foundation.h>
#include "pccontrol/Task.h"

@implementation TLinkInProcessBridgeAdapter

- (NSString *)runtimeLocation { return @"in-process-prototype"; }

// Run processTask() once and return its raw reply string (or nil on failure).
static NSString *TLinkRunProcessTaskSync(NSInteger taskCode, NSString *taskPayload) {
    NSString *wire = [NSString stringWithFormat:@"%ld;;%@", (long)taskCode, taskPayload ?: @""];
    NSData *requestData = [wire dataUsingEncoding:NSUTF8StringEncoding];
    if (!requestData) return nil;

    // Bound stream pair: processTask writes into writeStream, we read readStream.
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreateBoundPair(kCFAllocatorDefault, &readStream, &writeStream, 1024 * 1024);
    if (!readStream || !writeStream) {
        if (readStream) CFRelease(readStream);
        if (writeStream) CFRelease(writeStream);
        return nil;
    }

    CFReadStreamOpen(readStream);
    CFWriteStreamOpen(writeStream);

    // Mutable, NUL-terminated copy of the request for the C API.
    size_t len = requestData.length;
    UInt8 *buff = (UInt8 *)malloc(len + 1);
    if (!buff) {
        CFReadStreamClose(readStream); CFWriteStreamClose(writeStream);
        CFRelease(readStream); CFRelease(writeStream);
        return nil;
    }
    memcpy(buff, requestData.bytes, len);
    buff[len] = 0;

    // processTask writes the reply and closes the write side when done.
    processTask(buff, writeStream);
    free(buff);
    CFWriteStreamClose(writeStream);

    // Drain the read side fully.
    NSMutableData *out = [NSMutableData data];
    UInt8 chunk[8192];
    while (true) {
        CFIndex n = CFReadStreamRead(readStream, chunk, sizeof(chunk));
        if (n > 0) { [out appendBytes:chunk length:(NSUInteger)n]; continue; }
        break; // 0 = EOF, <0 = error
    }
    CFReadStreamClose(readStream);
    CFRelease(readStream);
    CFRelease(writeStream);

    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

- (TLinkJSNativeResult *)performTaskCode:(NSInteger)taskCode
                             taskPayload:(NSString *)taskPayload
                                 options:(TLinkJSNativeCallOptions *)options
                             isCancelled:(BOOL (^)(void))isCancelled {
    NSInteger deadlineMs = (options.deadlineMs > 0) ? options.deadlineMs : kTLinkJSDefaultNativeDeadlineMs;

    if (isCancelled && isCancelled()) {
        return [TLinkJSNativeResult transportFailure:kTLinkJSErrNativeCancelled];
    }

    static dispatch_queue_t worker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        worker = dispatch_queue_create("com.tlinkauto.jshelper.inproc-native",
                                       DISPATCH_QUEUE_CONCURRENT);
    });

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString *reply = nil;
    dispatch_async(worker, ^{
        reply = TLinkRunProcessTaskSync(taskCode, taskPayload);
        dispatch_semaphore_signal(done);
    });

    // Wait in short slices so cancellation is observed without busy-spinning.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(deadlineMs / 1000.0)];
    const int64_t sliceNs = 50 * NSEC_PER_MSEC;
    while (true) {
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, sliceNs)) == 0) {
            break; // worker finished
        }
        if (isCancelled && isCancelled()) {
            return [TLinkJSNativeResult transportFailure:kTLinkJSErrNativeCancelled];
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            return [TLinkJSNativeResult transportFailure:kTLinkJSErrNativeTimeout];
        }
    }

    if (!reply) {
        return [TLinkJSNativeResult transportFailure:@"native_no_reply"];
    }

    NSArray<NSString *> *parts = [reply componentsSeparatedByString:@";;"];
    BOOL ok = parts.count > 0 && [parts[0] isEqualToString:@"0"];
    return [TLinkJSNativeResult resultWithOk:ok raw:reply parts:parts];
}

@end
