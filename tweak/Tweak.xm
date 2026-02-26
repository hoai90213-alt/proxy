#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <string.h>

static NSString *const kLuminaProxydConfigPath = @"/var/mobile/Library/Preferences/com.project.lumina.proxyd.json";
static const NSTimeInterval kConfigReloadInterval = 1.0;
static const size_t kMaxRewritePorts = 8;

typedef struct {
    BOOL enabled;
    in_port_t localProxyPort; // network byte order
    uint16_t rewritePorts[kMaxRewritePorts]; // host byte order
    size_t rewritePortCount;
} LuminaProxyHookConfig;

static LuminaProxyHookConfig gHookConfig;
static NSTimeInterval gLastConfigLoad = 0;
static NSTimeInterval gLastRedirectLog = 0;
static BOOL gDidLogBoot = NO;

static void LPApplyDefaultConfig(void) {
    memset(&gHookConfig, 0, sizeof(gHookConfig));
    gHookConfig.enabled = YES;
    gHookConfig.localProxyPort = htons(19132);
    gHookConfig.rewritePorts[0] = 19132;
    gHookConfig.rewritePorts[1] = 19133;
    gHookConfig.rewritePortCount = 2;
}

static BOOL LPPortInRewriteList(uint16_t portHostOrder) {
    for (size_t i = 0; i < gHookConfig.rewritePortCount; i++) {
        if (gHookConfig.rewritePorts[i] == portHostOrder) {
            return YES;
        }
    }
    return NO;
}

static void LPLogConfig(const char *reason) {
    NSMutableString *ports = [NSMutableString string];
    for (size_t i = 0; i < gHookConfig.rewritePortCount; i++) {
        if (i > 0) [ports appendString:@","];
        [ports appendFormat:@"%u", gHookConfig.rewritePorts[i]];
    }

    NSLog(@"[LuminaProxyTweak] config(%s): enabled=%d localProxyPort=%u rewritePorts=[%@]",
          reason,
          gHookConfig.enabled,
          ntohs(gHookConfig.localProxyPort),
          ports);
}

static void LPLoadConfigIfNeeded(BOOL force) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!force && (now - gLastConfigLoad) < kConfigReloadInterval) {
        return;
    }
    gLastConfigLoad = now;

    LuminaProxyHookConfig previous = gHookConfig;
    LuminaProxyHookConfig next;
    memset(&next, 0, sizeof(next));
    next.enabled = YES;
    next.localProxyPort = htons(19132);
    next.rewritePorts[0] = 19132;
    next.rewritePorts[1] = 19133;
    next.rewritePortCount = 2;

    NSData *data = [NSData dataWithContentsOfFile:kLuminaProxydConfigPath];
    if (!data) {
        gHookConfig = next;
        if (!gDidLogBoot) {
            LPLogConfig("default-no-file");
            gDidLogBoot = YES;
        }
        return;
    }

    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[LuminaProxyTweak] config parse error: %@", error ?: @"invalid root object");
        gHookConfig = next;
        return;
    }

    NSDictionary *json = (NSDictionary *)obj;

    id tweakEnabledValue = json[@"tweakEnabled"];
    if ([tweakEnabledValue isKindOfClass:[NSNumber class]]) {
        next.enabled = [((NSNumber *)tweakEnabledValue) boolValue];
    }

    id localProxyPortValue = json[@"localProxyPort"];
    if ([localProxyPortValue isKindOfClass:[NSNumber class]]) {
        NSInteger port = [((NSNumber *)localProxyPortValue) integerValue];
        if (port > 0 && port <= 65535) {
            next.localProxyPort = htons((uint16_t)port);
        }
    }

    NSArray *ports = nil;
    id rewritePortsValue = json[@"rewritePorts"];
    if ([rewritePortsValue isKindOfClass:[NSArray class]]) {
        ports = (NSArray *)rewritePortsValue;
    } else if ([json[@"tweakRewritePorts"] isKindOfClass:[NSArray class]]) {
        ports = (NSArray *)json[@"tweakRewritePorts"];
    }

    if (ports) {
        next.rewritePortCount = 0;
        for (id value in ports) {
            if (![value isKindOfClass:[NSNumber class]]) continue;
            NSInteger port = [((NSNumber *)value) integerValue];
            if (port <= 0 || port > 65535) continue;
            if (next.rewritePortCount >= kMaxRewritePorts) break;
            next.rewritePorts[next.rewritePortCount++] = (uint16_t)port;
        }

        if (next.rewritePortCount == 0) {
            next.rewritePorts[0] = 19132;
            next.rewritePortCount = 1;
        }
    }

    BOOL configChanged = (memcmp(&previous, &next, sizeof(LuminaProxyHookConfig)) != 0);
    gHookConfig = next;

    if (configChanged || !gDidLogBoot) {
        LPLogConfig(configChanged ? "reload" : "initial");
    }
    gDidLogBoot = YES;
}

static BOOL LPSocketIsUDP(int sockfd) {
    int type = 0;
    socklen_t len = sizeof(type);
    if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &type, &len) != 0) {
        return NO;
    }
    return (type & SOCK_DGRAM) == SOCK_DGRAM;
}

static BOOL LPIsIPv4Loopback(const struct sockaddr_in *addr) {
    uint32_t host = ntohl(addr->sin_addr.s_addr);
    return ((host >> 24) & 0xFF) == 127;
}

static BOOL LPIsIPv6Loopback(const struct sockaddr_in6 *addr) {
    return IN6_IS_ADDR_LOOPBACK(&addr->sin6_addr);
}

static BOOL LPShouldRedirectAddress(const struct sockaddr *addr, socklen_t addrlen) {
    if (!addr || addrlen < sizeof(sa_family_t)) return NO;

    switch (addr->sa_family) {
        case AF_INET: {
            if (addrlen < sizeof(struct sockaddr_in)) return NO;
            const struct sockaddr_in *a = (const struct sockaddr_in *)addr;
            if (LPIsIPv4Loopback(a)) return NO;
            return LPPortInRewriteList(ntohs(a->sin_port));
        }
        case AF_INET6: {
            if (addrlen < sizeof(struct sockaddr_in6)) return NO;
            const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)addr;
            if (LPIsIPv6Loopback(a)) return NO;
            return LPPortInRewriteList(ntohs(a->sin6_port));
        }
        default:
            return NO;
    }
}

static BOOL LPBuildLoopbackRedirect(const struct sockaddr *originalAddr,
                                    socklen_t originalLen,
                                    struct sockaddr_storage *outStorage,
                                    socklen_t *outLen) {
    if (!originalAddr || !outStorage || !outLen) return NO;
    memset(outStorage, 0, sizeof(*outStorage));

    switch (originalAddr->sa_family) {
        case AF_INET: {
            if (originalLen < sizeof(struct sockaddr_in)) return NO;
            struct sockaddr_in *dst = (struct sockaddr_in *)outStorage;
            dst->sin_family = AF_INET;
            dst->sin_len = sizeof(struct sockaddr_in);
            dst->sin_port = gHookConfig.localProxyPort;
            dst->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            *outLen = sizeof(struct sockaddr_in);
            return YES;
        }
        case AF_INET6: {
            if (originalLen < sizeof(struct sockaddr_in6)) return NO;
            struct sockaddr_in6 *dst = (struct sockaddr_in6 *)outStorage;
            dst->sin6_family = AF_INET6;
            dst->sin6_len = sizeof(struct sockaddr_in6);
            dst->sin6_port = gHookConfig.localProxyPort;
            dst->sin6_addr = in6addr_loopback;
            *outLen = sizeof(struct sockaddr_in6);
            return YES;
        }
        default:
            return NO;
    }
}

static void LPLogRedirectOncePerCall(const char *api, const struct sockaddr *originalAddr) {
    if (!originalAddr) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ((now - gLastRedirectLog) < 1.0) {
        return;
    }
    gLastRedirectLog = now;

    char ipbuf[INET6_ADDRSTRLEN] = {0};
    uint16_t port = 0;

    if (originalAddr->sa_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)originalAddr;
        inet_ntop(AF_INET, &a->sin_addr, ipbuf, sizeof(ipbuf));
        port = ntohs(a->sin_port);
    } else if (originalAddr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)originalAddr;
        inet_ntop(AF_INET6, &a->sin6_addr, ipbuf, sizeof(ipbuf));
        port = ntohs(a->sin6_port);
    } else {
        return;
    }

    NSLog(@"[LuminaProxyTweak] %s redirect %s:%u -> 127.0.0.1:%u",
          api, ipbuf, port, ntohs(gHookConfig.localProxyPort));
}

%hookf(int, connect, int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    LPLoadConfigIfNeeded(NO);

    if (!gHookConfig.enabled) {
        return %orig(sockfd, addr, addrlen);
    }

    if (!LPSocketIsUDP(sockfd) || !LPShouldRedirectAddress(addr, addrlen)) {
        return %orig(sockfd, addr, addrlen);
    }

    struct sockaddr_storage redirected;
    socklen_t redirectedLen = 0;
    if (!LPBuildLoopbackRedirect(addr, addrlen, &redirected, &redirectedLen)) {
        return %orig(sockfd, addr, addrlen);
    }

    LPLogRedirectOncePerCall("connect", addr);
    return %orig(sockfd, (const struct sockaddr *)&redirected, redirectedLen);
}

%hookf(ssize_t, sendto, int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen) {
    LPLoadConfigIfNeeded(NO);

    if (!gHookConfig.enabled || !dest_addr) {
        return %orig(sockfd, buf, len, flags, dest_addr, addrlen);
    }

    if (!LPSocketIsUDP(sockfd) || !LPShouldRedirectAddress(dest_addr, addrlen)) {
        return %orig(sockfd, buf, len, flags, dest_addr, addrlen);
    }

    struct sockaddr_storage redirected;
    socklen_t redirectedLen = 0;
    if (!LPBuildLoopbackRedirect(dest_addr, addrlen, &redirected, &redirectedLen)) {
        return %orig(sockfd, buf, len, flags, dest_addr, addrlen);
    }

    LPLogRedirectOncePerCall("sendto", dest_addr);
    return %orig(sockfd, buf, len, flags, (const struct sockaddr *)&redirected, redirectedLen);
}

%ctor {
    @autoreleasepool {
        LPApplyDefaultConfig();
        LPLoadConfigIfNeeded(YES);
        NSLog(@"[LuminaProxyTweak] Loaded (UDP redirect hooks active)");
    }
}
