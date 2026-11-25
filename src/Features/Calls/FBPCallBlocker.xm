// Stop the sideloaded Facebook app ringing for Messenger calls: with both
// installed each registers for VoIP, both ring, and neither answers cleanly.
//
// Strip PKPushTypeVoIP from -setDesiredPushTypes: so Apple routes call pushes
// to Messenger (the real fix), and no-op -[CXProvider
// reportNewIncomingCallWithUUID:…] for a push that slipped through before the
// hook installed. Nothing in UNUserNotificationCenter or APNs registration is
// touched, so non-call notifications keep working. Always on.

#import "FBPlus.h"
#import "FBPTrace.h"

#import <PushKit/PushKit.h>
#import <CallKit/CallKit.h>
#import <objc/runtime.h>

%group FBPCallBlocker

%hook PKPushRegistry

- (void)setDesiredPushTypes:(NSSet<PKPushType> *)desiredPushTypes {
    FBPTraceFire("calls.PKPushRegistry.setDesiredPushTypes");
    if ([desiredPushTypes containsObject:PKPushTypeVoIP]) {
        NSMutableSet *stripped = [desiredPushTypes mutableCopy];
        [stripped removeObject:PKPushTypeVoIP];
        desiredPushTypes = stripped;
    }
    %orig(desiredPushTypes);
}

%end

%hook CXProvider

- (void)reportNewIncomingCallWithUUID:(NSUUID *)UUID
                               update:(CXCallUpdate *)update
                           completion:(void (^)(NSError *error))completion {
    FBPTraceFire("calls.CXProvider.reportNewIncomingCall");
    // Still invoke the completion so Facebook's call setup does not hang on it.
    if (completion) completion(nil);
}

%end

%end // FBPCallBlocker

void FBPInitCallBlocker(void) {
    FBP_ONCE(gCallBlocker) { %init(FBPCallBlocker); }
}
