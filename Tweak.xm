#include <dlfcn.h>
#include <stdlib.h>

@import CommonCrypto;
@import Foundation;
@import UIKit;

#import <FrontBoardServices/FBSSystemService.h>
#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SpringBoard.h>
#import <SpringBoardServices/SBSRelaunchAction.h>

#import <Cephei/HBPreferences.h>

#import "util.h"

@interface SBCoverSheetPresentationManager
+ (id)sharedInstance;
@end

@interface SBFDeviceLockOutController
- (void)temporaryBlockStatusChanged;
@end

@interface SBFMobileKeyBagUnlockOptions : NSObject
@property (nonatomic,copy,readonly) NSData * passcode;
@end

@interface SBLockScreenManager
+ (id)sharedInstance;
- (void)lockScreenViewControllerRequestsUnlock;
@end

HBPreferences *prefs;
BOOL isUnlocked;
BOOL didStartBlock = NO;
int lastLockTime = 0;
__weak SBFDeviceLockOutController *lockOutController = NULL;

BOOL isEnabled() {
    return [prefs boolForKey:@"enabled"] && [[prefs objectForKey:@"passcodeHash"] length] > 0;
}

BOOL doUnlock(NSString *passcode) {
    NSString *salt = [prefs objectForKey:@"passcodeSalt"];

    if ([generateHashFor(passcode, salt) isEqualToString:[prefs objectForKey:@"passcodeHash"]]) {
        NSLog(@"Successful unlock with passcode: %@", passcode);
        isUnlocked = YES;
        [prefs setInteger:0 forKey:@"failedAttempts"];
        return YES;
    } else {
        NSLog(@"Failed unlock with passcode: %@", passcode);
        int failedAttempts = [prefs integerForKey:@"failedAttempts"] + 1;
        [prefs setInteger:failedAttempts forKey:@"failedAttempts"];
        if (failedAttempts >= 6 && [prefs boolForKey:@"blockAfterTooManyFailures"]) {
            [prefs setInteger:[NSDate date].timeIntervalSince1970 forKey:@"blockTime"];
            if (lockOutController != NULL) {
                NSLog(@"Triggering device lockout due to too many failed attempts");
                [lockOutController temporaryBlockStatusChanged];
            }
        }
        return NO;
    }
}

%group FakePassUIKit

%hook DevicePINController
- (int)pinLength {
    if (!isEnabled()) {
        return %orig;
    }

    int passcodeType = [prefs integerForKey:@"passcodeType"];
    int length;

    switch (passcodeType) {
        case 0:
            length = 4;
            break;
        case 1:
            length = 6;
            break;
        default:
            return %orig;
    }

    NSLog(@"Spoofing passcode length: %d", length);
    return length;
}

- (BOOL)isNumericPIN {
    if (!isEnabled()) {
        return %orig;
    }

    int passcodeType = [prefs integerForKey:@"passcodeType"];
    BOOL forceAlphanumeric = [prefs boolForKey:@"forceAlphanumeric"];

    if (forceAlphanumeric) {
        return NO;
    }

    return passcodeType < 3;
}

- (BOOL)simplePIN {
    if (!isEnabled()) {
        return %orig;
    }

    int passcodeType = [prefs integerForKey:@"passcodeType"];
    BOOL hideLength = [prefs boolForKey:@"hideLength"];
    BOOL forceAlphanumeric = [prefs boolForKey:@"forceAlphanumeric"];

    if (hideLength || forceAlphanumeric) {
        return NO;
    }

    return passcodeType < 3;
}
%end

%hook MCPasscodeManager
- (BOOL)isPasscodeSet {
    if (!isEnabled()) {
        return %orig;
    }

    if (((NSString *)[prefs objectForKey:@"passcodeHash"]).length > 0) {
        NSLog(@"Spoofing passcode state");
        return YES;
    }

    return NO;
}
%end

%hook MCProfileConnection
- (BOOL)unlockDeviceWithPasscode:(id)passcode outError:(id *)error {
    if (!isEnabled()) {
        return %orig;
    }

    NSString *salt = [prefs objectForKey:@"passcodeSalt"];

    if ([generateHashFor(passcode, salt) isEqualToString:[prefs objectForKey:@"passcodeHash"]]) {
        NSLog(@"Successful authentication with passcode: %@", passcode);
        return YES;
    } else {
        NSLog(@"Failed authentication with passcode: %@", passcode);
        return NO;
    }
}
%end

%hookf(NSInteger, SBUICurrentPasscodeStyleForUser) {
    if (!isEnabled()) {
        return %orig;
    }

    int passcodeType = [prefs integerForKey:@"passcodeType"];
    BOOL hideLength = [prefs boolForKey:@"hideLength"];
    BOOL forceAlphanumeric = [prefs boolForKey:@"forceAlphanumeric"];

    if (forceAlphanumeric) {
        return 3;
    }

    if (passcodeType < 2 && hideLength) {
        return 2;
    }

    return passcodeType;
}

%end

%group FakePassSB

%hook SBBacklightController
- (void) _startFadeOutAnimationFromLockSource:(int)arg1 {
    if (!isEnabled()) {
        return %orig;
    }

    if (isUnlocked) {
        [[%c(SBLockScreenManager) sharedInstance] lockScreenViewControllerRequestsUnlock];
    }
    %orig;
}
%end

%hook SBDoubleClickSleepWakeHardwareButtonInteraction
- (void)_performSleep {
    if (!isEnabled()) {
        return %orig;
    }

    if (isUnlocked) {
        [[%c(SBLockScreenManager) sharedInstance] lockScreenViewControllerRequestsUnlock];
    }
    %orig;
}
%end

%hook SBFDeviceBlockTimer
- (NSString *)subtitleText {
    if (!isEnabled()) {
        return %orig;
    }

    int failedAttempts = [prefs integerForKey:@"failedAttempts"];
    NSTimeInterval blockTime = [prefs integerForKey:@"blockTime"];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval lockoutTime;

    if (failedAttempts <= 10) {
        if (failedAttempts >= 10) {
            lockoutTime = 3600;
        } else if (failedAttempts >= 8) {
            lockoutTime = 900;
        } else if (failedAttempts >= 7) {
            lockoutTime = 300;
        } else if (failedAttempts >= 6) {
            lockoutTime = 60;
        } else {
            return %orig;
        }
    } else {
        return %orig;
    }

    NSTimeInterval remainingSecs = (blockTime + lockoutTime) - now;
    int remainingMins = ceil(remainingSecs / 60);
    NSString *s = (remainingMins == 1) ? @"" : @"s";

    return [NSString stringWithFormat:@"try again in %d minute%@", remainingMins, s];
}
%end

%hook SBFDeviceLockOutController
- (id)initWithThermalController:(id)arg1 authenticationController:(id)arg2 {
    if (!isEnabled()) {
        return %orig;
    }

    lockOutController = self;
    return %orig;
}

- (BOOL)isPermanentlyBlocked {
    if (!isEnabled()) {
        return %orig;
    }

    return [prefs integerForKey:@"failedAttempts"] > 10;
}

- (BOOL)isTemporarilyBlocked {
    if (!isEnabled()) {
        return %orig;
    }

    if (![prefs boolForKey:@"blockAfterTooManyFailures"]) {
        return NO;
    }

    NSTimeInterval blockTime = [prefs integerForKey:@"blockTime"];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    int failedAttempts = [prefs integerForKey:@"failedAttempts"];
    NSTimeInterval lockoutTime = 0;

    if (failedAttempts <= 10) {
        if (failedAttempts >= 10) {
            lockoutTime = 3600;
        } else if (failedAttempts >= 8) {
            lockoutTime = 900;
        } else if (failedAttempts >= 7) {
            lockoutTime = 300;
        } else if (failedAttempts >= 6) {
            lockoutTime = 60;
        } else {
            return NO;
        }
    }

    return now < blockTime + lockoutTime;
}
%end

%hook SBFMobileKeyBag
// iOS 14
- (BOOL)unlockWithPasscode:(NSString *)passcode error:(id *)error {
    if (!isEnabled()) {
        return %orig;
    }

    return doUnlock(passcode);
}

// iOS 15
- (BOOL)unlockWithOptions:(SBFMobileKeyBagUnlockOptions *)options error:(id *)error {
    if (!isEnabled()) {
        return %orig;
    }

    return doUnlock([[NSString alloc] initWithData:[options passcode] encoding:NSUTF8StringEncoding]);
}
%end

%hook SBFMobileKeyBagState
- (NSInteger)lockState {
    if (!isEnabled()) {
        return %orig;
    }

    return isUnlocked ? 0 : 2;
}
%end

%hook SBFUserAuthenticationController
- (BOOL)isAuthenticated {
    if (!isEnabled()) {
        return %orig;
    }

    return isUnlocked;
}

- (BOOL)isAuthenticatedCached {
    if (!isEnabled()) {
        return %orig;
    }

    return isUnlocked;
}
%end

%hook SBLockScreenManager
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (!isEnabled()) {
        return %orig;
    }

    NSLog(@"Screen locked from source: %d", source);

    if (((NSString *)[prefs objectForKey:@"passcodeHash"]).length > 0) {
        NSLog(@"Locking device");
        isUnlocked = NO;
        lastLockTime = [NSDate date].timeIntervalSince1970;
    }

    %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    if (!isEnabled() || source == 24) {
        // 24 = Screen already unlocked, swiping up on the lock screen
        return %orig;
    }

    NSLog(@"Screen unlocked from source: %d", source);

    if (lockOutController != NULL) {
        NSLog(@"Clearing device lockout");
        int blockTime = [prefs integerForKey:@"blockTime"];
        [prefs removeObjectForKey:@"blockTime"];
        [lockOutController temporaryBlockStatusChanged];
        [prefs setInteger:blockTime forKey:@"blockTime"];
        [lockOutController temporaryBlockStatusChanged];
    }

    if (!isUnlocked) {
        NSTimeInterval lockAfter = [prefs integerForKey:@"lockAfter"];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;

        if (lastLockTime > 0 && lockAfter > 0 && lastLockTime + (lockAfter * 60) > now) {
            NSLog(@"Unlocking due to grace period");
            isUnlocked = YES;
        }
    }

    %orig;
}
%end

%hook SBMainWorkspace
- (void)dismissPowerDownTransientOverlayWithCompletion:(id)arg1 {
    if (!isEnabled()) {
        return %orig;
    }

    if (((NSString *)[prefs objectForKey:@"passcodeHash"]).length > 0) {
        if (isUnlocked) {
            [[%c(SBLockScreenManager) sharedInstance] lockScreenViewControllerRequestsUnlock];
        }

        isUnlocked = NO;
    }

    %orig;
}
%end

%hook SOSManager
- (void)didDismissClientSOSBeforeSOSCall:(id)arg1 {
    if (!isEnabled()) {
        return %orig;
    }

    if (((NSString *)[prefs objectForKey:@"passcodeHash"]).length > 0) {
        if (isUnlocked) {
            [[%c(SBLockScreenManager) sharedInstance] lockScreenViewControllerRequestsUnlock];
        }

        isUnlocked = NO;
    }

    %orig;
}
%end

%end

%ctor {
    @autoreleasepool {
        NSString *bundleId = [NSBundle mainBundle].bundleIdentifier;

        NSLog(@"Injected into %@", bundleId);

        /*if ([bundleId isEqualToString:@"com.apple.Spotlight"]) {
            // Workaround for safe mode glitch
            return;
        }*/

        prefs = [[HBPreferences alloc] initWithIdentifier:@"net.cadoth.fakepass"];

        [prefs registerDefaults:@{
            @"enabled": @YES,
            @"lockOnRespring": @YES,
            @"hideLength": @NO,
            @"forceAlphanumeric": @NO,
            @"blockAfterTooManyFailures": @YES,
            @"lockAfter": @0,
        }];

        if (!isEnabled()) {
            return;
        }

        isUnlocked = ((NSString *)[prefs objectForKey:@"passcodeHash"]).length == 0 || ![prefs boolForKey:@"lockOnRespring"];

        NSLog(@"Loading FakePassUIKit");
        void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardUIServices.framework/SpringBoardUIServices", RTLD_LAZY);
        %init(FakePassUIKit, SBUICurrentPasscodeStyleForUser = dlsym(handle, "SBUICurrentPasscodeStyleForUser"));

        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"Loading FakePassSB");
            %init(FakePassSB);
        }
    }
}
