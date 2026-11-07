// The tier-2 decline. See FBPDav1dBridge.h for the measurements behind it.
//
// This file contains no dav1d struct declaration and calls no dav1d function,
// on purpose. Declaring the layouts "ready for when we turn it on" is how a
// hand-written `Dav1dPicture` ends up being passed to a 1.0.0 that disagrees
// about it; there is nothing to get wrong while there is nothing here.

#import "FBPDav1dBridge.h"

BOOL FBPDav1dTierIsAvailable(void) {
    // Not "not implemented yet" — refused. The symbols are there and resolve;
    // what is missing is any guarantee about *which* dav1d answers, and any
    // verified layout for the one that does.
    return NO;
}

NSString *FBPDav1dTierDeclineReason(void) {
    return @"dav1d tier declined: FBSharedFramework ships 1.5.1 and WebCore "
           @"ships 1.0.0 in the same process, so dlsym(RTLD_DEFAULT) cannot be "
           @"trusted to return one ABI; no verified struct layout.";
}
