// =============================================================================
// TLinkJSIPCChannel.mm  (Phase 1 - IPC transport)
// -----------------------------------------------------------------------------
// Length-prefixed JSON framing over an AF_UNIX stream socket. See header.
//
// Framing:   [uint32 big-endian payload length][UTF-8 JSON payload]
// A length of 0 is illegal; lengths over kMaxFrameBytes are treated as a
// protocol violation and tear the connection down (defensive: a desynced
// stream must never make us allocate gigabytes).
//
// Threading model:
//   * One dedicated read thread runs the blocking read loop. It parses frames
//     and hands each decoded envelope to onMessage on _deliveryQueue (serial),
//     so handlers never overlap and never run on the read thread.
//   * sendMessage: serializes writes under _writeLock and uses writev with a
//     retry loop for partial writes.
//   * close is idempotent and safe to call from any thread / from inside a
//     handler.
// =============================================================================

#import "TLinkJSIPCChannel.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <arpa/inet.h>   // htonl / ntohl
#include <atomic>

// Hard ceiling on a single frame. Large native payloads go via file handles
// (Phase 5), so the control/event channel itself never needs huge frames.
static const uint32_t kTLinkJSMaxFrameBytes = 16u * 1024u * 1024u;  // 16 MiB

@implementation TLinkJSIPCChannel {
    int                 _fd;
    NSThread           *_readThread;
    dispatch_queue_t    _deliveryQueue;
    NSLock             *_writeLock;
    std::atomic<bool>   _closed;
    std::atomic<bool>   _disconnectFired;
}

#pragma mark - Lifecycle

- (instancetype)initWithSocketFD:(int)fd {
    self = [super init];
    if (!self) return nil;

    _fd = fd;
    _closed.store(false);
    _disconnectFired.store(false);
    _writeLock = [[NSLock alloc] init];
    _deliveryQueue = dispatch_queue_create("com.tlinkauto.jsd.ipc.delivery", DISPATCH_QUEUE_SERIAL);

    // Keep writes from killing us with SIGPIPE; we want EPIPE instead.
    int one = 1;
    setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    _readThread = [[NSThread alloc] initWithTarget:self selector:@selector(_readLoop) object:nil];
    _readThread.name = @"com.tlinkauto.jsd.ipc.read";
    [_readThread start];

    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    // Flip the flag exactly once; whoever wins does the teardown.
    bool expected = false;
    if (!_closed.compare_exchange_strong(expected, true)) {
        return;
    }
    int fd = _fd;
    _fd = -1;
    if (fd >= 0) {
        // shutdown() unblocks a blocking read() on the read thread.
        shutdown(fd, SHUT_RDWR);
        ::close(fd);
    }
    [self _fireDisconnectOnce];
}

- (void)_fireDisconnectOnce {
    bool expected = false;
    if (!_disconnectFired.compare_exchange_strong(expected, true)) {
        return;
    }
    void (^cb)(void) = self.onDisconnect;
    if (cb) {
        dispatch_async(_deliveryQueue, ^{ cb(); });
    }
}

#pragma mark - Read loop

// Read exactly `len` bytes into buf. Returns NO on EOF/error/close.
- (BOOL)_readFully:(void *)buf length:(size_t)len {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        if (_closed.load()) return NO;
        ssize_t n = read(_fd, p + got, len - got);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n == 0) {
            return NO;  // clean EOF (peer closed)
        }
        if (errno == EINTR) continue;
        return NO;      // hard error
    }
    return YES;
}

- (void)_readLoop {
    @autoreleasepool {
        while (!_closed.load()) {
            uint32_t beLen = 0;
            if (![self _readFully:&beLen length:sizeof(beLen)]) break;

            uint32_t len = ntohl(beLen);
            if (len == 0 || len > kTLinkJSMaxFrameBytes) {
                // Protocol violation / stream desync -> bail.
                break;
            }

            NSMutableData *data = [NSMutableData dataWithLength:len];
            if (!data) break;
            if (![self _readFully:data.mutableBytes length:len]) break;

            NSError *err = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (![obj isKindOfClass:[NSDictionary class]]) {
                // A malformed frame is not fatal to the stream; skip it.
                continue;
            }
            NSDictionary *message = (NSDictionary *)obj;
            void (^cb)(NSDictionary *) = self.onMessage;
            if (cb) {
                dispatch_async(_deliveryQueue, ^{
                    @autoreleasepool { cb(message); }
                });
            }
        }
    }
    // Loop ended -> connection is gone. Surface it.
    [self _fireDisconnectOnce];
    [self close];
}

#pragma mark - Writing

- (BOOL)sendMessage:(NSDictionary *)message {
    if (_closed.load()) return NO;

    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:&err];
    if (!json) return NO;
    if (json.length == 0 || json.length > kTLinkJSMaxFrameBytes) return NO;

    uint32_t beLen = htonl((uint32_t)json.length);

    [_writeLock lock];
    BOOL ok = NO;
    @try {
        if (_closed.load()) { ok = NO; }
        else {
            ok = [self _writeAll:&beLen length:sizeof(beLen)] &&
                 [self _writeAll:json.bytes length:json.length];
        }
    } @finally {
        [_writeLock unlock];
    }
    if (!ok) {
        // A failed write means the peer is gone; tear down.
        [self close];
    }
    return ok;
}

// Caller must hold _writeLock.
- (BOOL)_writeAll:(const void *)buf length:(size_t)len {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        if (_closed.load()) return NO;
        ssize_t n = write(_fd, p + sent, len - sent);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // Socket is blocking by default, but guard anyway: wait writable.
            struct pollfd pfd = { .fd = _fd, .events = POLLOUT };
            poll(&pfd, 1, 1000);
            continue;
        }
        return NO;  // EPIPE / hard error
    }
    return YES;
}

#pragma mark - Factories

+ (nullable instancetype)acceptOnPath:(NSString *)path timeoutMs:(NSInteger)timeoutMs {
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath || strlen(cpath) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        return nil;
    }

    // Remove any stale socket file from a previous (crashed) helper.
    unlink(cpath);

    int listenfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenfd < 0) return nil;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, cpath, sizeof(addr.sun_path));

    if (bind(listenfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        ::close(listenfd);
        return nil;
    }
    // Owner rw so SpringBoard (running as mobile) can connect.
    chmod(cpath, 0600);

    if (listen(listenfd, 1) != 0) {
        ::close(listenfd);
        unlink(cpath);
        return nil;
    }

    // Wait for one client with a timeout.
    struct pollfd pfd = { .fd = listenfd, .events = POLLIN };
    int pr = poll(&pfd, 1, (timeoutMs > 0) ? (int)timeoutMs : -1);
    if (pr <= 0) {
        ::close(listenfd);
        unlink(cpath);
        return nil;  // timeout or error
    }

    int clientfd = accept(listenfd, NULL, NULL);
    // We only ever serve one client; stop listening once accepted.
    ::close(listenfd);
    if (clientfd < 0) {
        unlink(cpath);
        return nil;
    }

    return [[self alloc] initWithSocketFD:clientfd];
}

+ (nullable instancetype)connectToPath:(NSString *)path timeoutMs:(NSInteger)timeoutMs {
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath || strlen(cpath) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        return nil;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, cpath, sizeof(addr.sun_path));

    // Non-blocking connect so we can bound it with poll().
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc != 0) {
        if (errno != EINPROGRESS) { ::close(fd); return nil; }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        int pr = poll(&pfd, 1, (timeoutMs > 0) ? (int)timeoutMs : -1);
        if (pr <= 0) { ::close(fd); return nil; }
        int soerr = 0; socklen_t l = sizeof(soerr);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &l);
        if (soerr != 0) { ::close(fd); return nil; }
    }

    // Back to blocking for the simple read/write loops.
    fcntl(fd, F_SETFL, flags);
    return [[self alloc] initWithSocketFD:fd];
}

@end
