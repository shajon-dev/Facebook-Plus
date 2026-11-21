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

#import "FBPlus.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#if FBP_DIAG

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

%hook FBBundledLanguagePackLoader

- (id)loadLanguagePackFromBundle:(id)bundle fbLocale:(id)locale {
    id pack = %orig;
    FBPDiag(@"i18n", @"bundled loader locale=%@ -> %@", locale, pack ? @"ok" : @"nil");
    return pack;
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

#endif // FBP_DIAG

#pragma mark - Init

void FBPInitLanguagePackHooks(void) {
#if FBP_DIAG
    if (objc_getClass("FBFlatBufferLanguagePack")) {
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
    FBP_ONCE(gLanguagePackErrors) { %init(FBPLanguagePackErrors); }
#endif
}
