TARGET := iphone:clang:latest:15.1
# arm64 only. This targets iPhone 11 → latest, all sideloaded / re-signed: those
# apps run in the arm64 slice even on A12+ (arm64e) devices — the arm64e slice is
# reserved for Apple-signed platform binaries — so an injected arm64e slice would
# never load. Dropping it also removes the "incompatible arm64e ABI" linker warning.
ARCHS  := arm64
INSTALL_TARGET_PROCESSES = Facebook

# Set to 1 (or export in your environment) when building for a roothide
# jailbreak, which needs the .jbroot loader-path indirection.
THEOS_PACKAGE_SCHEME ?= rootless
THEOS ?= $(HOME)/theos

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FacebookPlus

FacebookPlus_FILES = \
	src/Core/FBPlus.m \
	src/Core/FBPPrefs.m \
	src/Core/FBPResources.m \
	src/Core/FBPTrace.m \
	src/Core/FBPEntry.xm \
	src/UI/Toast/FBPToastWindow.m \
	src/UI/Toast/FBPToastView.m \
	src/UI/Toast/FBPToastManager.m \
	src/UI/Sheet/FBPSheetPresenter.m \
	src/UI/Sheet/FBPSheetController.m \
	src/UI/Sheet/FBPDetentPresentationController.m \
	src/Settings/FBPSettingsController.m \
	src/Features/Onboarding/FBPWelcomeController.m \
	src/Features/AppIcons/FBPAppIconController.m \
	src/Features/Language/FBPLanguageController.m \
	src/Features/Feed/FBPFeedHooks.xm \
	src/Features/Feed/FBPFeedSurveyHooks.xm \
	src/Features/Ads/FBPAdsHooks.xm \
	src/Features/Comments/FBPCommentHooks.xm \
	src/Features/Reels/FBPReelsSurveyHooks.xm \
	src/Features/Reels/FBPReelsMidCardHooks.xm \
	src/Features/Stories/FBPStoryHooks.xm \
	src/Features/Sidebar/FBPSidebarHooks.xm \
	src/Features/Confirmation/FBPConfirmHooks.xm \
	src/Features/Confirmation/FBPActionConfirm.mm \
	src/Features/AppChrome/FBPChromeHooks.xm \
	src/Features/OLED/FBPOLEDHooks.xm \
	src/Features/HDR/FBPHDRHooks.xm \
	src/Features/FacebookPlus/FBPPlusHooks.xm \
	src/Features/Fonts/FBPFontHooks.xm \
	src/Features/Fonts/FBPFontController.m \
	src/Features/Downloads/FBPDashManifest.m \
	src/Features/Downloads/FBPDownloadVariants.m \
	src/Features/Downloads/FBPMediaMuxer.m \
	src/Features/Downloads/FBPPhotoSave.m \
	src/Features/Downloads/FBPDav1dBridge.m \
	src/Features/Downloads/FBPMediaConverter.m \
	src/Features/Downloads/FBPVP9Bridge.m \
	src/Features/Downloads/FBPVP9Converter.m \
	src/Features/Downloads/FBPDashDownload.m \
	src/Features/Downloads/FBPDownloadStore.m \
	src/Features/Downloads/FBPDownloadManagerController.m \
	src/Features/Downloads/FBPReelsDownloader.xm \
	src/Features/Downloads/FBPStoryDownloader.xm \
	src/Features/Links/FBPLinkHooks.xm \
	src/Features/Links/FBPLinkBridge.xm \
	src/Features/Calls/FBPCallBlocker.xm \
	src/Features/Notifications/FBPNotifClientSync.xm \
	src/Features/Notifications/FBPLocalNotify.xm \
	src/Features/Update/FBPUpdateController.m \
	src/Features/Update/FBPUpdateChecker.m \
	src/PluginsInject/PluginsInject.mm \
	src/PluginsInject/Paths.mm \
	src/PluginsInject/SecRebinds.xm \
	src/PluginsInject/SideloadFix.xm \
	src/PluginsInject/NotifDiag.mm \
	src/Core/fishhook/fishhook.c

# The tweak's own version, read from control, exposed to the code as FBP_VERSION
# (an NSString literal) so the update checker can compare against GitHub releases.
FBP_VERSION := $(shell awk -F': ' '/^Version:/{print $$2; exit}' control)

# Every directory a source may #import a sibling header from. One list, used by
# the compiler below, by the .clangd the compile-commands target writes, and by
# scripts/doctor.py — so the editor and the typechecker cannot drift from the
# build the way they silently did when each kept its own copy.
FBP_INCLUDE_DIRS = \
	src/Core \
	src/UI \
	src/UI/Toast \
	src/UI/Sheet \
	src/Settings \
	src/Features \
	src/Features/AppChrome \
	src/Features/AppIcons \
	src/Features/Calls \
	src/Features/Confirmation \
	src/Features/Downloads \
	src/Features/Feed \
	src/Features/Fonts \
	src/Features/Language \
	src/Features/Links \
	src/Features/Notifications \
	src/Features/OLED \
	src/Features/Onboarding \
	src/Features/Stories \
	src/Features/Update \
	src/PluginsInject

FacebookPlus_CFLAGS  = -fobjc-arc -Wno-deprecated-declarations \
	-DFBP_VERSION='@"$(FBP_VERSION)"' \
	$(addprefix -I,$(FBP_INCLUDE_DIRS))
# VideoToolbox and CoreVideo are for FBPMediaConverter: the AV1-decoder
# capability probe calls VTDecompressionSessionCreate directly, and the decode
# side hands back CVPixelBuffers.
# Diagnostic build. FBP_DIAG=1 compiles in the [FBPDIAG] os_log trace that
# src/PluginsInject/Header.h declares — the keychain and container decisions, on
# subsystem com.shajon.fbplus. Off by default, and it must stay off in a release:
# the lines name keychain services. See FBPNotifyBridge/README.md.
ifeq ($(FBP_DIAG),1)
FacebookPlus_CFLAGS += -DFBP_DIAG=1
endif

FacebookPlus_FRAMEWORKS = UIKit Foundation Photos QuartzCore CoreGraphics CoreText AVFoundation CoreMedia CoreVideo VideoToolbox Security PushKit CallKit UserNotifications

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += resources
include $(THEOS_MAKE_PATH)/aggregate.mk

# Editor support. Without a compilation database, clangd and the VS Code C/C++
# extension cannot find the iOS SDK and every Foundation type reads as
# "Unknown type name".
#
# We cannot let bear *intercept* the build: theos compiles with the Xcode
# toolchain's Apple-signed clang, and macOS strips DYLD_INSERT_LIBRARIES (bear's
# interception mechanism) from hardened-runtime Apple binaries, so `bear -- make`
# only ever records an empty "[]". Instead we use bear's `parse-sh`, which reads
# theos's own dry-run (`make -n`) and turns each compile into a database entry
# with the real flags — no interception, works on any macOS. theos wraps every
# compile in a `( … )` subshell that parse-sh would skip, so the sed first
# unwraps it to a bare command. Logos .xm files appear as their preprocessed
# .theos/obj/…/<name>.xm.mm; editing the original .xm is covered by .clangd above.
.PHONY: compile-commands
compile-commands:
	@command -v bear >/dev/null 2>&1 || { \
		echo "error: bear is not installed."; \
		echo "       Debian/Ubuntu: sudo apt install bear"; \
		echo "       macOS:         brew install bear"; \
		exit 1; \
	}
	@echo "==> Generating .clangd…"
	@sdk=$$(ls -d "$(THEOS)"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1); \
	if [ -z "$$sdk" ]; then \
		echo "error: no iPhoneOS SDK found under $(THEOS)/sdks"; exit 1; \
	fi; \
	sdkver=$$(basename "$$sdk" .sdk | sed 's/^iPhoneOS//'); \
	{ \
		echo "CompileFlags:"; \
		echo "  Add:"; \
		echo "    - -target"; \
		echo "    - arm64-apple-ios$$sdkver"; \
		echo "    - -isysroot"; \
		echo "    - $$sdk"; \
		echo "    - -I$(THEOS)/include"; \
		echo "    - -I$(THEOS)/include/iphone"; \
		echo "    - -I$(THEOS)/vendor/include"; \
		echo "    - -I$(THEOS)/include/_fallback"; \
		echo "    - -F$$sdk/System/Library/Frameworks"; \
		echo "    - -F$$sdk/System/Library/PrivateFrameworks"; \
		echo "    - -F$(THEOS)/vendor/lib"; \
		for d in $(FBP_INCLUDE_DIRS); do echo "    - -I$$(pwd)/$$d"; done; \
		echo "    - -DTARGET_IPHONE=1"; \
		echo "    - -DDEBUG"; \
		echo "    - -DFBP_VERSION=@\"$(FBP_VERSION)\""; \
		echo "    - -fobjc-arc"; \
		echo "    - -Wno-deprecated-declarations"; \
		echo "    - -ferror-limit=0"; \
		echo ""; \
		echo "Diagnostics:"; \
		echo "  Suppress:"; \
		echo "    - unknown_type_name"; \
		echo "    - undeclared_var_use"; \
		echo "    - undeclared_var_use_suggest"; \
		echo "    - duplicate_decl_context"; \
		echo "    - expected_unqualified_id"; \
		echo "    - err_expected_unqualified"; \
		echo "    - expected_either"; \
		echo "    - expected_expression"; \
		echo "    - missing_method_context"; \
		echo "    - invalid_token_after_toplevel_declarator"; \
		echo "    - fatal_too_many_errors"; \
	} > .clangd
	@echo "==> Recording compile commands with bear…"
	@$(MAKE) clean >/dev/null
	@$(MAKE) -n | sed -E 's/.*set -o pipefail; \(//; s/\)[[:space:]]*$$//' \
		| bear parse-sh -o compile_commands.json 2>/dev/null
	@echo "==> Wrote compile_commands.json and .clangd"

# Every check scripts/doctor.py has: the four shipped configurations
# typechecked in parallel, both targets actually linked, and the repository's
# own rules over whatever git tracks. This target runs all of them: a check
# that has to be requested separately tends not to be run at all.
.PHONY: check
check:
	@python3 scripts/doctor.py
