// =============================================================================
// TLinkJSRuntimeCore.mm  (Phase 0 - Core Extraction)
// -----------------------------------------------------------------------------
// SpringBoard-independent JavaScript runtime core. See TLinkJSRuntimeCore.h.
//
// What was lifted out of TLinkautoJSRuntime.mm and kept verbatim in behavior:
//   * Private watchdog via dlsym(JSContextGroupSetExecutionTimeLimit) + a
//     one-time self-test (TLinkautoJSRunWatchdogSelfTest equivalent).
//   * std::atomic<bool> abort flag consumed by the watchdog "should terminate"
//     callback so an infinite loop is killed without touching the JSContext
//     from another thread.
//   * NSCondition-based interruptible sleep().
//   * console/module/helper preludes (require/include, TLinkauto.* helpers).
//
// What changed (the whole point of the extraction):
//   * Native calls no longer call processTask() directly. They go through
//     id<TLinkJSNativeBridge>, so the SAME core runs in-process or in the
//     helper daemon. The JS-facing `device.*` surface is provided by the host
//     (TLinkautoDeviceBridge in-process; a thin JSExport shim in the helper),
//     which calls back into -performNativeTaskCode:payload: below.
// =============================================================================

#import "TLinkJSRuntimeCore.h"
#import "TLinkJSProtocol.h"

#import <JavaScriptCore/JavaScriptCore.h>
#import <os/lock.h>
#include <atomic>
#include <dlfcn.h>
#include <math.h>

// ---- Private watchdog function pointer types (same as legacy runtime) -------
typedef bool (*TLinkJSShouldTerminateCallback)(JSContextRef ctx, void *opaque);
typedef void (*TLinkJSSetExecutionTimeLimitFn)(JSContextGroupRef group, double limit, TLinkJSShouldTerminateCallback callback, void *opaque);
typedef void (*TLinkJSClearExecutionTimeLimitFn)(JSContextGroupRef group);

static const double kTLinkJSWatchdogInterval = 0.1; // seconds

struct TLinkJSCoreCancelState {
    std::atomic<bool> aborted;
};

struct TLinkJSCoreWatchdogProbe {
    std::atomic<int> callbacks;
};

static bool TLinkJSCoreShouldTerminate(JSContextRef ctx, void *opaque) {
    (void)ctx;
    TLinkJSCoreCancelState *state = (TLinkJSCoreCancelState *)opaque;
    return state && state->aborted.load(std::memory_order_acquire);
}

static bool TLinkJSCoreWatchdogProbeCallback(JSContextRef ctx, void *opaque) {
    (void)ctx;
    TLinkJSCoreWatchdogProbe *state = (TLinkJSCoreWatchdogProbe *)opaque;
    if (state) state->callbacks.fetch_add(1, std::memory_order_relaxed);
    return false;
}

static BOOL TLinkJSCoreWatchdogSelfTest(TLinkJSSetExecutionTimeLimitFn setLimit, TLinkJSClearExecutionTimeLimitFn clearLimit) {
    if (!setLimit || !clearLimit) return NO;
    TLinkJSCoreWatchdogProbe state;
    state.callbacks.store(0, std::memory_order_relaxed);
    JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
    if (!ctx) return NO;
    JSContextGroupRef group = JSContextGetGroup(ctx);
    setLimit(group, 0.001, TLinkJSCoreWatchdogProbeCallback, &state);
    JSStringRef script = JSStringCreateWithUTF8CString("var end=Date.now()+20;var x=0;while(Date.now()<end){x++;}x;");
    JSValueRef exception = NULL;
    JSEvaluateScript(ctx, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    clearLimit(group);
    JSGlobalContextRelease(ctx);
    return exception == NULL && state.callbacks.load(std::memory_order_relaxed) > 0;
}

static BOOL TLinkJSCoreWatchdogCapability(TLinkJSSetExecutionTimeLimitFn setLimit, TLinkJSClearExecutionTimeLimitFn clearLimit) {
    static dispatch_once_t once;
    static BOOL capable = NO;
    dispatch_once(&once, ^{ capable = TLinkJSCoreWatchdogSelfTest(setLimit, clearLimit); });
    return capable;
}

static BOOL TLinkJSCoreIsFinite(double v) { return isfinite(v); }

// =============================================================================

@implementation TLinkJSConsoleEntry
@end

@interface TLinkJSRuntimeCore () {
    TLinkJSCoreCancelState *_cancelState;
    NSCondition *_sleepCondition;
    BOOL _running;
    NSString *_runId;
    NSString *_bundlePath;
    NSDictionary *_manifest;
    JSContext *_context;

    TLinkJSSetExecutionTimeLimitFn _setExecutionTimeLimit;
    TLinkJSClearExecutionTimeLimitFn _clearExecutionTimeLimit;
    BOOL _watchdogAvailable;

    os_unfair_lock _logLock;
    uint64_t _logSequence;
}
@end

// Lightweight JS-facing shim so the core can host a `device` object without the
// host having to define JSExport in two places. The host registers native task
// handling by setting `nativeBridge`; this shim forwards to the core which
// forwards to the bridge. Hosts that want the full rich `device.*` API (with
// per-method argument shaping) can instead inject their own object as `device`
// before calling evaluate; the core does not overwrite an existing `device`.
@protocol TLinkJSCoreDeviceExport <JSExport>
JSExportAs(runTask, - (NSDictionary *)runTask:(int)task payload:(NSString *)payload);
- (NSDictionary *)runtimeInfo;
@end

@interface TLinkJSCoreDeviceShim : NSObject <TLinkJSCoreDeviceExport>
@property (nonatomic, weak) TLinkJSRuntimeCore *core;
@end

@implementation TLinkJSRuntimeCore

- (instancetype)init {
    self = [super init];
    if (self) {
        _cancelState = new TLinkJSCoreCancelState();
        _cancelState->aborted.store(false, std::memory_order_release);
        _sleepCondition = [[NSCondition alloc] init];
        _logLock = OS_UNFAIR_LOCK_INIT;
        _logSequence = 0;
        _setExecutionTimeLimit = (TLinkJSSetExecutionTimeLimitFn)dlsym(RTLD_DEFAULT, "JSContextGroupSetExecutionTimeLimit");
        _clearExecutionTimeLimit = (TLinkJSClearExecutionTimeLimitFn)dlsym(RTLD_DEFAULT, "JSContextGroupClearExecutionTimeLimit");
        _watchdogAvailable = TLinkJSCoreWatchdogCapability(_setExecutionTimeLimit, _clearExecutionTimeLimit);
    }
    return self;
}

- (void)dealloc { delete _cancelState; }

- (BOOL)running { return _running; }
- (NSString *)runId { return _runId ?: @""; }
- (BOOL)watchdogAvailable { return _watchdogAvailable; }

#pragma mark - Cancellation (callable from the control queue)

- (void)requestStop {
    _cancelState->aborted.store(true, std::memory_order_release);
    [_sleepCondition lock];
    [_sleepCondition broadcast];
    [_sleepCondition unlock];
}

- (BOOL)isAborted {
    return _cancelState->aborted.load(std::memory_order_acquire);
}

- (void)setAbortExceptionIfNeeded {
    if (![self isAborted] || !_context) return;
    _context.exception = [JSValue valueWithNewErrorFromMessage:@"AbortError: script execution was stopped" inContext:_context];
}

- (BOOL)interruptibleSleepMs:(double)ms {
    if (!TLinkJSCoreIsFinite(ms) || ms < 0) {
        [self throwError:@"sleep(ms) requires a finite non-negative number"];
        return NO;
    }
    const double cap = 24.0 * 60.0 * 60.0 * 1000.0;
    if (ms > cap) ms = cap;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(ms / 1000.0)];
    [_sleepCondition lock];
    while (![self isAborted]) {
        if (![_sleepCondition waitUntilDate:deadline]) break;
    }
    [_sleepCondition unlock];
    [self setAbortExceptionIfNeeded];
    return ![self isAborted];
}

- (void)throwError:(NSString *)message {
    if (_context) {
        _context.exception = [JSValue valueWithNewErrorFromMessage:(message ?: @"JavaScript runtime error") inContext:_context];
    }
}

#pragma mark - Watchdog

- (void)installWatchdogForContext:(JSContext *)context {
    if (!_watchdogAvailable || !context) return;
    JSContextGroupRef group = JSContextGetGroup([context JSGlobalContextRef]);
    _setExecutionTimeLimit(group, kTLinkJSWatchdogInterval, TLinkJSCoreShouldTerminate, _cancelState);
}

- (void)clearWatchdogForContext:(JSContext *)context {
    if (!_watchdogAvailable || !context) return;
    JSContextGroupRef group = JSContextGetGroup([context JSGlobalContextRef]);
    _clearExecutionTimeLimit(group);
}

#pragma mark - Console

- (void)emitLogLevel:(NSString *)level message:(NSString *)message {
    os_unfair_lock_lock(&_logLock);
    uint64_t seq = ++_logSequence;
    os_unfair_lock_unlock(&_logLock);

    TLinkJSConsoleEntry *entry = [[TLinkJSConsoleEntry alloc] init];
    entry.sequence = seq;
    entry.level = level ?: @"log";
    entry.message = [message isKindOfClass:[NSString class]] ? message : ([message description] ?: @"");
    entry.timestamp = [[NSDate date] timeIntervalSince1970];

    id<TLinkJSRuntimeCoreDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(runtimeCore:didLogEntry:)]) {
        [d runtimeCore:self didLogEntry:entry];
    }
}

#pragma mark - Native bridge entry point (called by the device shim / host)

- (NSDictionary *)performNativeTaskCode:(NSInteger)taskCode payload:(NSString *)payload {
    if ([self isAborted]) {
        [self setAbortExceptionIfNeeded];
        return @{ @"ok": @NO, @"raw": @"1;;AbortError\r\n", @"parts": @[@"1", @"AbortError"] };
    }
    id<TLinkJSNativeBridge> bridge = self.nativeBridge;
    if (!bridge) {
        return @{ @"ok": @NO, @"raw": @"1;;bridge_missing\r\n", @"parts": @[@"1", @"bridge_missing"] };
    }
    TLinkJSNativeCallOptions *opts = [TLinkJSNativeCallOptions optionsWithDeadlineMs:0];
    opts.sessionId = _runId;
    __weak TLinkJSRuntimeCore *weakSelf = self;
    TLinkJSNativeResult *res = [bridge performTaskCode:taskCode
                                          taskPayload:(payload ?: @"")
                                              options:opts
                                          isCancelled:^BOOL{ return [weakSelf isAborted]; }];
    if (res.transportError) {
        // RPC-level failure (timeout/cancel/disconnect). Surface as a JS error.
        [self throwError:[NSString stringWithFormat:@"native RPC failed: %@", res.transportError]];
        return @{ @"ok": @NO, @"raw": [NSString stringWithFormat:@"1;;%@\r\n", res.transportError],
                  @"parts": @[@"1", res.transportError] };
    }
    return @{ @"ok": @(res.ok), @"raw": res.raw ?: @"", @"parts": res.parts ?: @[] };
}

#pragma mark - Preludes

- (NSString *)consolePrelude {
    return
    @"(function(){\n"
     "  function fmt(args){ return Array.prototype.map.call(args, function(v){\n"
     "    try { if (typeof v === 'string') return v; return JSON.stringify(v); }\n"
     "    catch(e) { return String(v); } }).join(' '); }\n"
     "  this.console = {\n"
     "    log: function(){ _tlinkLog('log', fmt(arguments)); },\n"
     "    info: function(){ _tlinkLog('info', fmt(arguments)); },\n"
     "    warn: function(){ _tlinkLog('warn', fmt(arguments)); },\n"
     "    error: function(){ _tlinkLog('error', fmt(arguments)); } };\n"
     "})();";
}

#pragma mark - Evaluate

- (BOOL)evaluateScript:(NSString *)source
            scriptPath:(NSString *)scriptPath
            bundlePath:(NSString *)bundlePath
              manifest:(NSDictionary *)manifest
                 error:(NSError **)error {
    if (_running) {
        if (error) *error = [NSError errorWithDomain:@"com.tlinkauto.jscore" code:999
                              userInfo:@{NSLocalizedDescriptionKey:@"JavaScript runtime is busy."}];
        return NO;
    }
    if (![source isKindOfClass:[NSString class]]) {
        if (error) *error = [NSError errorWithDomain:@"com.tlinkauto.jscore" code:998
                              userInfo:@{NSLocalizedDescriptionKey:@"script source is required"}];
        return NO;
    }

    _running = YES;
    _runId = [[NSUUID UUID] UUIDString];
    _bundlePath = [bundlePath copy];
    _manifest = [manifest isKindOfClass:[NSDictionary class]] ? [manifest copy] : @{};
    _cancelState->aborted.store(false, std::memory_order_release);

    @try {
        JSVirtualMachine *vm = [[JSVirtualMachine alloc] init];
        JSContext *context = [[JSContext alloc] initWithVirtualMachine:vm];
        _context = context;

        __weak TLinkJSRuntimeCore *weakSelf = self;
        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            ctx.exception = exception;
            TLinkJSRuntimeCore *s = weakSelf;
            NSString *msg = [exception toString] ?: @"JavaScript exception";
            id<TLinkJSRuntimeCoreDelegate> d = s.delegate;
            if ([d respondsToSelector:@selector(runtimeCore:didThrowExceptionMessage:)]) {
                [d runtimeCore:s didThrowExceptionMessage:msg];
            }
        };

        // Host can inject a richer `device` before calling evaluate. Only
        // install the minimal shim if none is present.
        if (![context[@"device"] isObject]) {
            TLinkJSCoreDeviceShim *shim = [[TLinkJSCoreDeviceShim alloc] init];
            shim.core = self;
            context[@"device"] = shim;
        }
        context[@"manifest"] = _manifest ?: @{};
        context[@"sleep"] = ^(double ms) {
            TLinkJSRuntimeCore *s = weakSelf;
            if (s) [s interruptibleSleepMs:ms];
        };
        context[@"_tlinkLog"] = ^(NSString *level, NSString *message) {
            TLinkJSRuntimeCore *s = weakSelf;
            if (s) [s emitLogLevel:level message:message];
        };

        [self installWatchdogForContext:context];
        [context evaluateScript:[self consolePrelude] withSourceURL:[NSURL URLWithString:@"tlinkauto://console-prelude.js"]];
        NSURL *sourceURL = scriptPath ? [NSURL fileURLWithPath:scriptPath] : [NSURL URLWithString:@"tlinkauto://script.js"];
        [context evaluateScript:source withSourceURL:sourceURL];

        BOOL success = !context.exception && ![self isAborted];
        if (!success && error) {
            NSString *message = context.exception ? [context.exception toString] : @"JavaScript execution was stopped";
            *error = [NSError errorWithDomain:@"com.tlinkauto.jscore" code:999
                      userInfo:@{NSLocalizedDescriptionKey:(message ?: @"JavaScript error")}];
        }
        return success;
    } @finally {
        [self clearWatchdogForContext:_context];
        _context = nil;
        _bundlePath = nil;
        _manifest = nil;
        _running = NO;
    }
}

#pragma mark - runtimeInfo

- (NSDictionary *)runtimeInfoSnapshot {
    BOOL wd = _watchdogAvailable;
    NSDictionary *manifest = _manifest ?: @{};
    return @{
        @"engine": @"JavaScriptCore",
        @"apiVersion": @1,
        @"manifestEntry": [manifest[@"entry"] isKindOfClass:[NSString class]] ? manifest[@"entry"] : @"",
        @"watchdog": wd ? @"private-api" : @"unavailable",
        @"watchdogIntervalMs": @(wd ? (int)(kTLinkJSWatchdogInterval * 1000.0) : 0),
        @"hardJsCancellation": @(wd),
        @"cooperativeCancellation": @YES,
        @"runId": _runId ?: @"",
        @"protocolVersion": @(kTLinkJSProtocolVersion),
    };
}

@end

@implementation TLinkJSCoreDeviceShim
- (NSDictionary *)runTask:(int)task payload:(NSString *)payload {
    return [self.core performNativeTaskCode:task payload:payload] ?: @{ @"ok": @NO };
}
- (NSDictionary *)runtimeInfo {
    NSMutableDictionary *info = [[self.core runtimeInfoSnapshot] mutableCopy];
    info[@"runtimeLocation"] = [self.core.nativeBridge runtimeLocation] ?: @"unknown";
    return info;
}
@end

// =============================================================================
// Bridge value types
// =============================================================================

@implementation TLinkJSNativeResult
+ (instancetype)resultWithOk:(BOOL)ok raw:(NSString *)raw parts:(NSArray<NSString *> *)parts {
    TLinkJSNativeResult *r = [[self alloc] init];
    r.ok = ok; r.raw = raw ?: @""; r.parts = parts ?: @[]; r.transportError = nil;
    return r;
}
+ (instancetype)transportFailure:(NSString *)error {
    TLinkJSNativeResult *r = [[self alloc] init];
    r.ok = NO; r.raw = @""; r.parts = @[]; r.transportError = error ?: @"native_error";
    return r;
}
@end

@implementation TLinkJSNativeCallOptions
+ (instancetype)optionsWithDeadlineMs:(NSInteger)deadlineMs {
    TLinkJSNativeCallOptions *o = [[self alloc] init];
    o.deadlineMs = deadlineMs;
    return o;
}
@end
