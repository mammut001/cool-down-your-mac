#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns an array of @{ @"name": NSString, @"celsius": NSNumber }.
NSArray<NSDictionary<NSString *, id> *> *CoolDownCopyHIDTemperatures(void);

/// Enumerates sensor temperatures directly via block callback, avoiding
/// intermediate NSDictionary / NSNumber heap allocations on the polling path.
void CoolDownEnumerateHIDTemperatures(void (NS_NOESCAPE ^block)(NSString *name, double celsius));

/// Releases the persistent HID client and cached services. Safe to call from
/// any thread; the next CoolDownCopyHIDTemperatures call will re-create them.
void CoolDownHIDTeardown(void);

/// Stop new HID samples and release cached handles before system sleep.
void CoolDownHIDPrepareForSleep(void);

/// Re-enable sampling with fresh services after system wake.
void CoolDownHIDResumeAfterWake(void);

NS_ASSUME_NONNULL_END
