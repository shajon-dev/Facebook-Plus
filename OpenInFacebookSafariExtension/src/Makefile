# Builds the "Open in Facebook" Safari web extension as a .appex.
#
# The web-extension resources (manifest.json, content.js, google.js, popup.*,
# _locales/, images/) and the bundle Info.plist live in Resources/ and are copied
# to the .appex root by theos. build.sh injects the result into the app's PlugIns.

TARGET := iphone:clang:latest:15.1
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPEX_NAME = OpenInFacebookSafariExtension
OpenInFacebookSafariExtension_FILES = SafariWebExtensionHandler.m
OpenInFacebookSafariExtension_FRAMEWORKS = Foundation
OpenInFacebookSafariExtension_CFLAGS = -fobjc-arc
OpenInFacebookSafariExtension_INSTALL_PATH = /Applications/Facebook.app/PlugIns

include $(THEOS)/makefiles/appex.mk
