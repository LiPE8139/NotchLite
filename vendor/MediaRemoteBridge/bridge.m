// MediaRemoteBridge — reads every concurrent Now Playing session and prints it as JSON.
//
// Loaded by /usr/bin/perl (an Apple-signed binary): since macOS 15.4 MediaRemote refuses
// non-Apple callers, and going through perl is what gets us past that check.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef id   (*GetOriginFn)(void);
typedef void (*InfoFn)(id, id, id, dispatch_queue_t, void (^)(id));
typedef void (*GetActiveFn)(dispatch_queue_t, void (^)(id));

static void *MR = NULL;
static GetClientsFn pGetClients;
static GetOriginFn  pGetOrigin;
static InfoFn       pGetInfo;
static GetActiveFn  pGetActive;

static BOOL loadMediaRemote(void) {
    if (MR) return YES;
    MR = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!MR) return NO;
    pGetClients = (GetClientsFn)dlsym(MR, "MRMediaRemoteGetNowPlayingClients");
    pGetOrigin  = (GetOriginFn)dlsym(MR, "MRMediaRemoteGetLocalOrigin");
    pGetInfo    = (InfoFn)dlsym(MR, "MRMediaRemoteGetNowPlayingInfoForClient");
    pGetActive  = (GetActiveFn)dlsym(MR, "MRMediaRemoteGetNowPlayingClient");
    return pGetClients && pGetOrigin && pGetInfo;
}

static NSArray *fetchClients(void) {
    __block NSArray *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    pGetClients(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(NSArray *c) {
        result = c;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return result;
}

static NSDictionary *fetchInfo(id client, id origin) {
    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    pGetInfo(client, origin, nil, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(id d) {
        result = d;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return result;
}

/// JSON string escaping: quotes, backslashes and control characters; UTF-8 passes through.
static void appendEscaped(NSMutableString *out, NSString *value) {
    NSUInteger n = value.length;
    unichar buf[512];
    NSUInteger chunk = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [value characterAtIndex:i];
        if (c == '"' || c == '\\') {
            buf[chunk++] = '\\';
            buf[chunk++] = c;
        } else if (c < 0x20) {
            buf[chunk++] = '\\';
            buf[chunk++] = 'u';
            buf[chunk++] = '0';
            buf[chunk++] = '0';
            buf[chunk++] = "0123456789abcdef"[(c >> 4) & 0xF];
            buf[chunk++] = "0123456789abcdef"[c & 0xF];
        } else {
            buf[chunk++] = c;
        }
        if (chunk >= 480) { [out appendString:[NSString stringWithCharacters:buf length:chunk]]; chunk = 0; }
    }
    if (chunk) [out appendString:[NSString stringWithCharacters:buf length:chunk]];
}

static NSString *str(id info, NSString *key) {
    id v = info[key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static double num(id info, NSString *key) {
    id v = info[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

/// The session the system currently routes commands to, or nil.
///
/// It is not always part of MRMediaRemoteGetNowPlayingClients — a player that stopped but still
/// owns the slot drops out of that list — so it is merged in separately.
static id fetchActiveClient(void) {
    if (!pGetActive) return nil;
    __block id client = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    pGetActive(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(id c) {
        client = c;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return client;
}

/// One JSON line describing every session, or an empty list when nothing is playing.
static NSString *buildState(void) {
    NSMutableString *json = [NSMutableString stringWithString:@"{\"sources\":["];
    NSArray *clients = fetchClients();
    id origin = pGetOrigin();
    id activeClient = fetchActiveClient();
    NSString *active = [activeClient valueForKey:@"bundleIdentifier"];

    NSMutableArray *all = [NSMutableArray arrayWithArray:clients ?: @[]];
    if (activeClient && active.length) {
        BOOL present = NO;
        for (id c in all) {
            if ([[c valueForKey:@"bundleIdentifier"] isEqualToString:active]) { present = YES; break; }
        }
        if (!present) [all addObject:activeClient];
    }
    BOOL first = YES;

    for (id client in all) {
        NSString *bundle = [client valueForKey:@"bundleIdentifier"];
        if (bundle.length == 0) continue;
        NSDictionary *info = fetchInfo(client, origin);
        if (info.count == 0) continue;

        // A session with no metadata still counts: it may be the one the system routes commands
        // to, and dropping it would make every other session look un-driven.
        NSString *title = str(info, @"kMRMediaRemoteNowPlayingInfoTitle") ?: @"";

        if (!first) [json appendString:@","];
        first = NO;

        [json appendString:@"{\"bundle\":\""];
        appendEscaped(json, bundle);
        [json appendString:@"\",\"name\":\""];
        appendEscaped(json, [client valueForKey:@"displayName"] ?: bundle);
        [json appendString:@"\",\"pid\":"];
        [json appendFormat:@"%d", [[client valueForKey:@"processIdentifier"] intValue]];
        [json appendString:@",\"title\":\""];
        appendEscaped(json, title);
        [json appendString:@"\",\"artist\":\""];
        appendEscaped(json, str(info, @"kMRMediaRemoteNowPlayingInfoArtist") ?: @"");
        [json appendString:@"\",\"album\":\""];
        appendEscaped(json, str(info, @"kMRMediaRemoteNowPlayingInfoAlbum") ?: @"");
        [json appendString:@"\","];
        [json appendFormat:@"\"duration\":%.3f,\"elapsed\":%.3f,\"rate\":%.3f,",
                           num(info, @"kMRMediaRemoteNowPlayingInfoDuration"),
                           num(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime"),
                           num(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate")];
        BOOL playing = num(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate") > 0;
        [json appendFormat:@"\"playing\":%@,", playing ? @"true" : @"false"];
        [json appendFormat:@"\"active\":%@}", [bundle isEqualToString:active ?: @""] ? @"true" : @"false"];
    }
    [json appendString:@"]}"];
    return json;
}

/// Streams a line whenever the set of sessions or their metadata changes.
void bridge_stream(void) {
    if (!loadMediaRemote()) { printf("{\"error\":\"mediaremote unavailable\"}\n"); fflush(stdout); return; }
    NSString *last = nil;
    for (;;) {
        @autoreleasepool {
            NSString *state = buildState();
            if (![state isEqualToString:last]) {
                last = state;
                printf("%s\n", state.UTF8String);
                fflush(stdout);
            }
        }
        usleep(400 * 1000);
    }
}

/// Prints one line and exits — for testing from a shell.
void bridge_snapshot(void) {
    if (!loadMediaRemote()) { printf("{\"error\":\"mediaremote unavailable\"}\n"); return; }
    @autoreleasepool {
        printf("%s\n", buildState().UTF8String);
        fflush(stdout);
    }
}
