#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns an array of @{ @"name": NSString, @"celsius": NSNumber }.
NSArray<NSDictionary<NSString *, id> *> *CoolDownCopyHIDTemperatures(void);

NS_ASSUME_NONNULL_END
