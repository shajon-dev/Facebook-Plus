// Language packs: report what the loader did, so a sideloaded build that falls
// back to English can say why (issue #9).
//
// WHAT THE PATH ACTUALLY IS
//
// The thread on that issue carries two guesses, and both are wrong, so they are
// written down here rather than tried again.
//
//   * It is not FBCoreLocaleIsDownloadableLanguagePackEnabled. Forcing that off
//     needs MSHookFunction, which a sideloaded build cannot survive, and it was
//     reverted for that reason. It is also not what fails.
//   * It is not the App-Group container either, which is where the same symptom
//     in Messenger was traced. Facebook keeps a downloaded pack in its OWN
//     container, read off a device as
//     Documents/locales/<build>_<id>/<locale>.lproj/fbt_language_pack.bin, and
//     a sideloaded app can write there.
//
// What a working device does, traced on a jailbroken phone set to en-GB:
// FBFlatBufferLanguagePack is handed the pack as NSData and answers an object.
// Nothing under Documents/locales existed for Facebook on that phone, and
// neither FBBundledLanguagePackLoader nor FBLanguagePackArchive was called, so
// the data came from the bundled languages.lgpk by a path that is C++ rather
// than Objective-C. The archive carries 35 locales, en-GB and ar among them,
// which is to say every locale the issue names.
//
// WHY THIS IS A DIAGNOSTIC AND NOT A FIX
//
// The failure exists only on a sideloaded install, and neither phone here
// reproduces it: one is jailbroken, where the pack loads, and the other cannot
// be attached to. These hooks say which of the four steps was reached and what
// it answered, which is the one thing nobody has yet. They are compiled into
// the build only when it asks for them, and cost nothing otherwise.
//
// To read them, build with FBP_DIAG=1, install, reproduce the wall, and watch
// the device over USB:
//
//   idevicesyslog -u <udid> | grep FBPDIAG
//
// The answer to look for, in order: was the archive opened, was the locale
// found in it, was FBFlatBufferLanguagePack given any data, and did it answer
// nil. An NSError in the -3000 range alongside them means the file could not be
// created, which is the Messenger signature after all; anything else means it
// is not.
//
// FBBundledLanguagePackLoader is deliberately not watched. It looks like the
// obvious place and it is never called: three locales were traced end to end
// on device and every one went archive -> flatbuffer without it.

#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

/// Whether the diagnostic hooks below are installed. A constant rather than a
/// preprocessor fence around the hooks themselves: Logos lays its own preamble
/// down at the first %hook it sees, and wrapping that in #if took the preamble
/// out of a non-diagnostic build and left every later group without it. The
/// groups are compiled either way and the branch that installs them is dropped.
#if FBP_DIAG
static const BOOL kFBPLanguagePackDiagnostics = YES;
#else
static const BOOL kFBPLanguagePackDiagnostics = NO;
#endif

#pragma mark - The loader

%group FBPLanguagePackDiag

%hook FBFlatBufferLanguagePack

// The moment of truth: the pack is parsed here, whatever produced the bytes.
- (id)initWithLanguagePackData:(NSData *)data
                      fbLocale:(id)locale
            shouldVerifyBuffer:(BOOL)verify {
    id pack = %orig;
    FBPDiag(@"i18n", @"flatbuffer locale=%@ bytes=%lu verify=%d -> %@",
            locale, (unsigned long)data.length, verify, pack ? @"ok" : @"nil");
    return pack;
}

%end

%hook FBLanguagePackArchive

- (id)initWithArchivePath:(NSString *)path {
    FBPDiag(@"i18n", @"archive opened at %@", path);
    return %orig;
}

- (BOOL)decompressLanguage:(NSString *)language
                    toPath:(NSString *)path
             languageFound:(BOOL *)found {
    BOOL ok = %orig;
    FBPDiag(@"i18n", @"archive decompress %@ -> %@ ok=%d found=%d",
            language, path, ok, found ? *found : -1);
    return ok;
}

%end

%end // FBPLanguagePackDiag

#pragma mark - The failure

// Narrow on purpose. NSError is made constantly, so only the file-creation
// range is reported, and only once per domain and code: -3000 is
// NSURLErrorCannotCreateFile, which is the error the Messenger trace blamed.
%group FBPLanguagePackErrors

%hook NSError

+ (id)errorWithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)info {
    if (code <= -2900 && code >= -3100) {
        static NSMutableSet<NSString *> *seen;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet set]; });

        NSString *line = [NSString stringWithFormat:@"%@ %ld", domain, (long)code];
        BOOL fresh = NO;
        @synchronized (seen) {
            fresh = ![seen containsObject:line];
            if (fresh) [seen addObject:line];
        }
        if (fresh) {
            FBPDiag(@"i18n", @"file error %@ · %@", line,
                    info[NSFilePathErrorKey] ?: info[NSURLErrorFailingURLStringErrorKey] ?: @"(no path)");
        }
    }
    return %orig;
}

%end

%end // FBPLanguagePackErrors

#pragma mark - The wall at first launch

// Presses "Try Again" once, so the first launch in a downloaded language does
// not stop at a wall the user has to clear by hand.
//
// What is left of issue #9 is only this screen, and only the first time: pick a
// language, and the next launch shows "English (United Kingdom) wasn't
// downloaded. Try clearing space on your phone and try again." Tapping Try
// Again works, and so does picking the language again from Settings, which is
// how the issue was eventually reported as "it downloads now". The pack itself
// is fine: the device log shows it decompressed out of the bundled
// languages.lgpk and parsed, for both of the locales the issue names.
//
// So the pack is not missing, it is late. Facebook asks for it during startup
// and puts this screen up when it is not ready yet, rather than waiting, and
// the message it shows blames disk space, which is why the issue was first read
// as a storage problem.
//
// Pressing its own retry is the smallest thing that resolves it, and it is the
// same code path as the user's tap, analytics included. Once per launch: if the
// pack genuinely cannot be fetched, the screen comes back and stays, which is
// the honest outcome rather than a loop.

%group FBPLanguagePackWall

%hook FBDownloadLanguagePackInterstitialViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    FBPLanguagePackInterstitial *wall = (FBPLanguagePackInterstitial *)self;
    if (![wall respondsToSelector:@selector(_didTapRetryButton)]) {
        return;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FBPDiag(@"i18n", @"language wall shown at launch, retrying once");
        // A beat, so the controller has finished appearing and Facebook's own
        // retry sees a settled view: this runs from viewDidAppear:.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [wall _didTapRetryButton];
        });
    });
}

%end

%end // FBPLanguagePackWall

#pragma mark - Init

void FBPInitLanguagePackHooks(void) {
    if (objc_getClass("FBDownloadLanguagePackInterstitialViewController")) {
        FBP_ONCE(gLanguagePackWall) { %init(FBPLanguagePackWall); }
    }

    if (kFBPLanguagePackDiagnostics && objc_getClass("FBFlatBufferLanguagePack")) {
        FBP_ONCE(gLanguagePackDiag) {
            %init(FBPLanguagePackDiag);

            // Where a downloaded pack would land, and whether this install can
            // write there. On a re-signed build that is the first thing to
            // doubt, and it is one line rather than a guess.
            NSString *documents = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *locales = [documents stringByAppendingPathComponent:@"locales"];
            NSFileManager *fm = NSFileManager.defaultManager;
            FBPDiag(@"i18n", @"locales dir %@ exists=%d writable=%d",
                    locales, [fm fileExistsAtPath:locales],
                    [fm isWritableFileAtPath:documents ?: @""]);
            FBPDiag(@"i18n", @"preferred languages %@",
                    [NSLocale preferredLanguages].firstObject ?: @"(none)");
        }
    }
    if (kFBPLanguagePackDiagnostics) {
        FBP_ONCE(gLanguagePackErrors) { %init(FBPLanguagePackErrors); }
    }
}
