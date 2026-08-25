#import "IOHIDTemperatureBridge.h"
#import <dlfcn.h>
#import <os/lock.h>

typedef void *CoolDownHIDClient;
typedef void *CoolDownHIDService;
typedef void *CoolDownHIDEvent;

typedef CoolDownHIDClient (*CoolDownHIDCreate)(CFAllocatorRef);
typedef void (*CoolDownHIDSetMatching)(CoolDownHIDClient, CFDictionaryRef);
typedef CFArrayRef (*CoolDownHIDCopyServices)(CoolDownHIDClient);
typedef CFTypeRef (*CoolDownHIDCopyProperty)(CoolDownHIDService, CFStringRef);
typedef CoolDownHIDEvent (*CoolDownHIDCopyEvent)(CoolDownHIDService, int64_t, CoolDownHIDEvent, int32_t);
typedef double (*CoolDownHIDGetFloat)(CoolDownHIDEvent, uint32_t);

static CoolDownHIDCreate gCreate = NULL;
static CoolDownHIDSetMatching gSetMatching = NULL;
static CoolDownHIDCopyServices gCopyServices = NULL;
static CoolDownHIDCopyProperty gCopyProperty = NULL;
static CoolDownHIDCopyEvent gCopyEvent = NULL;
static CoolDownHIDGetFloat gGetFloat = NULL;
static BOOL gSymbolsReady = NO;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CoolDownHIDClient gClient = NULL;
static CFMutableArrayRef gServices = NULL;
static NSMutableArray<NSString *> *gNames = nil;
static NSTimeInterval gServicesUptime = 0;

static const NSTimeInterval kHIDServiceRefreshSeconds = 45;
static const NSTimeInterval kHIDEmptyRetrySeconds = 2;

static BOOL CoolDownLoadHIDSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!handle) {
            handle = RTLD_DEFAULT;
        }
        gCreate = dlsym(handle, "IOHIDEventSystemClientCreate");
        gSetMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching");
        gCopyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices");
        gCopyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty");
        gCopyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent");
        gGetFloat = dlsym(handle, "IOHIDEventGetFloatValue");
        gSymbolsReady = gCreate && gSetMatching && gCopyServices && gCopyProperty && gCopyEvent && gGetFloat;
    });
    return gSymbolsReady;
}

static void CoolDownHIDResetServicesLocked(void) {
    if (gServices) {
        CFRelease(gServices);
        gServices = NULL;
    }
    gNames = nil;
}

static BOOL CoolDownHIDShouldRefreshServices(NSTimeInterval now) {
    const CFIndex count = gServices ? CFArrayGetCount(gServices) : 0;
    if (count > 0) {
        return now - gServicesUptime >= kHIDServiceRefreshSeconds;
    }
    if (gServicesUptime <= 0) {
        return YES;
    }
    return now - gServicesUptime >= kHIDEmptyRetrySeconds;
}

static BOOL CoolDownHIDShouldSkipProduct(NSString *product) {
    return [product hasPrefix:@"PMU tdev"] ||
        [product hasPrefix:@"PMU ibuck"] ||
        [product hasPrefix:@"PMU ildo"];
}

static void CoolDownHIDRefreshServicesLocked(void) {
    if (!gClient) {
        gClient = gCreate(kCFAllocatorDefault);
        if (!gClient) {
            return;
        }
    }

    NSArray<NSDictionary *> *presets = @[
        @{@"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @5},
        @{@"PrimaryUsagePage": @(0xff05), @"PrimaryUsage": @5},
    ];

    CFMutableArrayRef nextServices = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    NSMutableArray<NSString *> *nextNames = [NSMutableArray array];

    for (NSDictionary *matching in presets) {
        gSetMatching(gClient, (__bridge CFDictionaryRef)matching);
        CFArrayRef services = gCopyServices(gClient);
        if (!services) {
            continue;
        }

        CFIndex total = CFArrayGetCount(services);
        for (CFIndex i = 0; i < total; i++) {
            CoolDownHIDService service = (CoolDownHIDService)CFArrayGetValueAtIndex(services, i);
            CFStringRef productRef = gCopyProperty(service, CFSTR("Product"));
            if (!productRef) {
                continue;
            }
            NSString *product = CFBridgingRelease(productRef);
            if (CoolDownHIDShouldSkipProduct(product)) {
                continue;
            }
            CFArrayAppendValue(nextServices, service);
            [nextNames addObject:product];
        }
        CFRelease(services);
    }

    CoolDownHIDResetServicesLocked();
    gServices = nextServices;
    gNames = nextNames;
    gServicesUptime = [NSProcessInfo processInfo].systemUptime;
}

NSArray<NSDictionary<NSString *, id> *> *CoolDownCopyHIDTemperatures(void) {
    if (!CoolDownLoadHIDSymbols()) {
        return @[];
    }

    // Phase 1: Under lock, refresh if needed and snapshot the service list.
    os_unfair_lock_lock(&gLock);

    const NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (CoolDownHIDShouldRefreshServices(now)) {
        CoolDownHIDRefreshServicesLocked();
    }

    if (!gClient || !gServices || gNames.count == 0) {
        os_unfair_lock_unlock(&gLock);
        return @[];
    }

    // Snapshot: retain current arrays so event sampling can proceed outside
    // the lock. Other callers that arrive during sampling will block only for
    // the brief snapshot copy, not for the full I/O sweep.
    CFArrayRef snapshotServices = CFRetain(gServices);
    NSArray<NSString *> *snapshotNames = [gNames copy];

    os_unfair_lock_unlock(&gLock);

    // Phase 2: Sample events outside the lock.
    NSMutableDictionary<NSString *, NSNumber *> *sums = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    CFIndex total = CFArrayGetCount(snapshotServices);
    CFIndex nameCount = (CFIndex)snapshotNames.count;
    if (nameCount < total) {
        total = nameCount;
    }

    NSInteger nullEventCount = 0;

    for (CFIndex i = 0; i < total; i++) {
        CoolDownHIDService service = (CoolDownHIDService)CFArrayGetValueAtIndex(snapshotServices, i);
        CoolDownHIDEvent event = gCopyEvent(service, 15, NULL, 0);
        if (!event) {
            nullEventCount++;
            continue;
        }
        double value = gGetFloat(event, 15u << 16);
        CFRelease(event);
        if (!isfinite(value) || value <= -20.0 || value >= 120.0) {
            continue;
        }

        NSString *name = snapshotNames[i];
        sums[name] = @((sums[name].doubleValue) + value);
        counts[name] = @((counts[name].integerValue) + 1);
    }

    CFRelease(snapshotServices);

    // Phase 3: If most events returned NULL the cached service handles are
    // likely stale (e.g. system sleep/wake cycle). Force a refresh on the
    // next poll instead of waiting for the 45-second timer.
    if (total > 0 && nullEventCount * 2 > total) {
        os_unfair_lock_lock(&gLock);
        gServicesUptime = 0;
        os_unfair_lock_unlock(&gLock);
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (NSString *name in sums) {
        NSInteger count = counts[name].integerValue;
        if (count <= 0) {
            continue;
        }
        double avg = sums[name].doubleValue / (double)count;
        [results addObject:@{@"name": name, @"celsius": @(avg)}];
    }
    return results;
}

void CoolDownHIDTeardown(void) {
    os_unfair_lock_lock(&gLock);
    CoolDownHIDResetServicesLocked();
    if (gClient) {
        CFRelease(gClient);
        gClient = NULL;
    }
    os_unfair_lock_unlock(&gLock);
}
