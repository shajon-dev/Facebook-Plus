TARGET := iphone:clang:latest:17.0
# arm64 only. This targets iPhone 11 → latest, all sideloaded / re-signed: those
# apps run in the arm64 slice even on A12+ (arm64e) devices — the arm64e slice is
# reserved for Apple-signed platform binaries — so an injected arm64e slice would
# never load. Dropping it also removes the "incompatible arm64e ABI" linker warning.
ARCHS  := arm64
INSTALL_TARGET_PROCESSES = Facebook

# Set to 1 (or export in your environment) when building for a roothide
# jailbreak, which needs the .jbroot loader-path indirection.
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FacebookPlus

FacebookPlus_FILES = \
	src/Core/FBPlus.m \
	src/Core/FBPPrefs.m \
	src/Core/FBPResources.m \
	src/Core/FBPDiagnostics.m \
	src/Core/FBPEntry.xm \
	src/UI/Toast/FBPToastWindow.m \
	src/UI/Toast/FBPToastView.m \
	src/UI/Toast/FBPToastManager.m \
	src/UI/Sheet/FBPSheetPresenter.m \
	src/UI/Sheet/FBPSheetController.m \
	src/UI/Sheet/FBPDetentPresentationController.m \
	src/Settings/FBPSettingsController.m \
	src/Features/Onboarding/FBPWelcomeController.m \
	src/Features/Diagnostics/FBPDiagnosticsController.m \
	src/Features/AppIcons/FBPAppIconController.m \
	src/Features/Language/FBPLanguageController.m \
	src/Features/Feed/FBPFeedHooks.xm \
	src/Features/Stories/FBPStoryHooks.xm \
	src/Features/LikeConfirmation/FBPConfirmHooks.xm \
	src/Features/AppChrome/FBPChromeHooks.xm \
	src/Features/OLED/FBPOLEDHooks.xm \
	src/Features/Menu/FBPMenuHooks.xm \
	src/Features/Downloads/FBPReelsDownloader.xm \
	src/Features/Downloads/FBPStoryDownloader.xm \
	src/PluginsInject/PluginsInject.mm \
	src/PluginsInject/Paths.mm \
	src/PluginsInject/SecRebinds.xm \
	src/PluginsInject/SideloadFix.xm \
	fishhook/fishhook.c

FacebookPlus_CFLAGS  = -fobjc-arc -Wno-deprecated-declarations \
	-Isrc/Core -Isrc/UI/Toast -Isrc/UI/Sheet -Isrc/Settings \
	-Isrc/Features/Onboarding -Isrc/Features/Diagnostics \
	-Isrc/Features/AppIcons -Isrc/Features/Language -Isrc/PluginsInject
FacebookPlus_FRAMEWORKS = UIKit Foundation Photos QuartzCore CoreGraphics AVFoundation CoreMedia Security

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += resources
include $(THEOS_MAKE_PATH)/aggregate.mk

# Editor support. Without a compilation database, clangd and the VS Code C/C++
# extension cannot find the iOS SDK and every Foundation type reads as
# "Unknown type name". bear records the flags theos actually used, so this needs
# a clean build to see every file.
.PHONY: compile-commands
compile-commands:
	@command -v bear >/dev/null 2>&1 || { \
		echo "error: bear is not installed."; \
		echo "       Debian/Ubuntu: sudo apt install bear"; \
		echo "       macOS:         brew install bear"; \
		exit 1; \
	}
	@if [ -f .clangd.template ]; then \
		echo "==> Generating .clangd from template…"; \
		sed "s|@@THEOS@@|$(THEOS)|g" .clangd.template > .clangd; \
		rm -f .clangd.template; \
	fi
	@echo "==> Recording compile commands with bear…"
	@$(MAKE) clean >/dev/null
	@bear -- $(MAKE) >/dev/null
	@echo "==> Wrote compile_commands.json"
