// Language packs: diagnostics for a sideloaded build that falls back to
// English, plus the one fix known to help.
//
// Two tempting causes are wrong. Not
// FBCoreLocaleIsDownloadableLanguagePackEnabled: forcing it off needs
// MSHookFunction, which a sideloaded build cannot survive, and it is not what
// fails. Not the App-Group container either; a downloaded pack lives in
// Facebook's own container under Documents/locales/, which a sideloaded app can
// write to. The bundled languages.lgpk reaches FBFlatBufferLanguagePack by a
// C++ path, so FBBundledLanguagePackLoader is deliberately not watched: it
// looks like the obvious place and is never called.

#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

/// A constant, not a #if around the hooks: Logos lays its preamble down at the
/// first %hook it sees, so fencing that leaves every later group without it.
/// The groups compile either way and the install branch is dropped.
#if FBP_DIAG
static const BOOL kFBPLanguagePackDiagnostics = YES;
#else
static const BOOL kFBPLanguagePackDiagnostics = NO;
#endif

#pragma mark - The loader

%group FBPLanguagePackDiag

%hook FBFlatBufferLanguagePack

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

// Narrow on purpose: NSError is made constantly, so only the file-creation
// range (-3000 is NSURLErrorCannotCreateFile) and once per domain and code.
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

// The pack is not missing, it is late: Facebook asks for it during startup and
// puts this wall up rather than waiting, with a message blaming disk space.
// Driving its own retry is the same path as the user's tap. Once per launch, so
// a pack that genuinely cannot be fetched leaves the screen up, not a loop.

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
        // This runs from viewDidAppear:, so wait for a settled view.
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

            // Where a downloaded pack would land, and whether a re-signed
            // install can write there.
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
