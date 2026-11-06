# Builds FBPNotifyBridge.dylib — the slim sideload-compat shim that build.sh
# injects into Facebook's NotificationServiceExtension.appex.
#
# Deliberately NOT a target of the root Makefile: a second target there would be
# packaged into the .deb, and cyan would then inject this dylib into the main
# binary as well, installing the NSFileManager / NSUserDefaults redirects twice.
# build.sh builds it on its own with `make -C`, the same way the Safari web
# extension under OpenInFacebookSafariExtension/*/Makefile is built.
#
# It links Foundation, Security and MobileCoreServices only — no UIKit, no
# settings / toast / font / feature code — so it stays small enough for an NSE's
# ~24 MB memory limit. MobileCoreServices is there to guarantee LSBundleProxy
# (used by Paths.mm) is loaded; the main app gets it for free because Facebook
# itself links CoreServices, an extension does not.

TARGET := iphone:clang:latest:15.1
ARCHS  := arm64

# Pinned to the empty (rootfull) scheme regardless of the environment: this dylib
# is only ever loaded from inside a re-signed .ipa, where the rootless
# loader-path indirection does not apply. A makefile assignment overrides an
# inherited THEOS_PACKAGE_SCHEME.
THEOS_PACKAGE_SCHEME :=
THEOS ?= $(HOME)/theos

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FBPNotifyBridge

# Shared with the main tweak — same sources, so the container mapping and the
# keychain access-group probe cannot drift between the two processes.
FBPNotifyBridge_FILES = \
	FBPNotifyBridge.mm \
	../../src/PluginsInject/Paths.mm \
	../../src/PluginsInject/PluginsInject.mm \
	../../src/PluginsInject/SecRebinds.xm \
	../../fishhook/fishhook.c

FBPNotifyBridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I../../src/PluginsInject
FBPNotifyBridge_FRAMEWORKS = Foundation Security MobileCoreServices
FBPNotifyBridge_INSTALL_PATH = /Applications/Facebook.app/PlugIns/NotificationServiceExtension.appex

include $(THEOS_MAKE_PATH)/library.mk
