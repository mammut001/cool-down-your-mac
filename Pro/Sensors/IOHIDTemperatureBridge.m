#import "IOHIDTemperatureBridge.h"
#import <dlfcn.h>

typedef void *CoolDownHIDClient;
typedef void *CoolDownHIDService;
typedef void *CoolDownHIDEvent;

NSArray<NSDictionary<NSString *, id> *> *CoolDownCopyHIDTemperatures(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) {
        handle = RTLD_DEFAULT;
    }

    CoolDownHIDClient (*create)(CFAllocatorRef) = dlsym(handle, "IOHIDEventSystemClientCreate");
    void (*setMatching)(CoolDownHIDClient, CFDictionaryRef) = dlsym(handle, "IOHIDEventSystemClientSetMatching");
    CFArrayRef (*copyServices)(CoolDownHIDClient) = dlsym(handle, "IOHIDEventSystemClientCopyServices");
    CFTypeRef (*copyProperty)(CoolDownHIDService, CFStringRef) = dlsym(handle, "IOHIDServiceClientCopyProperty");
    CoolDownHIDEvent (*copyEvent)(CoolDownHIDService, int64_t, CoolDownHIDEvent, int32_t) =
        dlsym(handle, "IOHIDServiceClientCopyEvent");
    double (*getFloat)(CoolDownHIDEvent, uint32_t) = dlsym(handle, "IOHIDEventGetFloatValue");

    if (!create || !setMatching || !copyServices || !copyProperty || !copyEvent || !getFloat) {
        return @[];
    }

    CoolDownHIDClient client = create(kCFAllocatorDefault);
    if (!client) {
        return @[];
    }

    NSArray<NSDictionary *> *presets = @[
        @{@"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @5},
        @{@"PrimaryUsagePage": @(0xff05), @"PrimaryUsage": @5},
    ];

    NSMutableDictionary<NSString *, NSNumber *> *sums = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];

    for (NSDictionary *matching in presets) {
        setMatching(client, (__bridge CFDictionaryRef)matching);
        CFArrayRef services = copyServices(client);
        if (!services) {
            continue;
        }

        CFIndex total = CFArrayGetCount(services);
        for (CFIndex i = 0; i < total; i++) {
            CoolDownHIDService service = (CoolDownHIDService)CFArrayGetValueAtIndex(services, i);
            CFStringRef productRef = copyProperty(service, CFSTR("Product"));
            if (!productRef) {
                continue;
            }
            NSString *product = CFBridgingRelease(productRef);
            if ([product hasPrefix:@"PMU tdev"] ||
                [product hasPrefix:@"PMU ibuck"] ||
                [product hasPrefix:@"PMU ildo"]) {
                continue;
            }

            CoolDownHIDEvent event = copyEvent(service, 15, NULL, 0);
            if (!event) {
                continue;
            }
            double value = getFloat(event, 15u << 16);
            CFRelease(event);
            if (!isfinite(value) || value <= -20.0 || value >= 120.0) {
                continue;
            }

            sums[product] = @((sums[product].doubleValue) + value);
            counts[product] = @((counts[product].integerValue) + 1);
        }
        CFRelease(services);
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

    CFRelease(client);
    return results;
}
