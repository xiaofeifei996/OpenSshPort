# use latest available SDK from theos instead of pinning 11.0 (which may not be installed in CI)
export TARGET = iphone:clang:latest:11.0
export ARCHS = arm64 arm64e
#messages=yes

PACKAGE_VERSION=$(shell cat version.txt)
ifeq ($(findstring a,$(PACKAGE_VERSION)),a)
  ALPHABETA=1
#else ifeq ($(findstring b,$(PACKAGE_VERSION)),b)
#  ALPHABETA=1
else
  ALPHABETA=0
endif

export THEOS_PACKAGE_SCHEME = $(if $(RF),rootful,rootless)
export THEOS_PACKAGE_INSTALL_PREFIX = /var/jb
# ^ using this for older Theos, sort of backporting from post 2023-03-26 Theos (which sets this var automatically).

# need to set the possible PREFIX before including common.mk
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
# if building for rootful, meaning iOS <= 14 or a checkm8 jb. Find some Xcode 11 toolchain so the arm64e slice is made with the "old" ABI.
XCODE11PATHS := $(wildcard /Applications/Xcode*11*app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin $(THEOS)/toolchain/Xcode*11*.xctoolchain/usr/bin)
ifneq ($(XCODE11PATHS),)
export PREFIX := $(lastword $(XCODE11PATHS))/
endif
# reset the jb root prefix for rootful
export THEOS_PACKAGE_INSTALL_PREFIX =
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OpenSshPort
$(BUNDLE_NAME)_BUNDLE_EXTENSION = bundle
$(BUNDLE_NAME)_CFLAGS += -fobjc-arc -fvisibility=hidden -DALPHABETA=$(ALPHABETA)
$(BUNDLE_NAME)_FILES = OpenSshPort.m
$(BUNDLE_NAME)_INSTALL_PATH = /Library/PreferenceBundles
$(BUNDLE_NAME)_PRIVATE_FRAMEWORKS = Preferences

# control file which we make in before-stage:: (want to make sure the arch is right, whatever was last manually written there)
_THEOS_DEB_PACKAGE_CONTROL_PATH = "$(THEOS_PROJECT_DIR)/control-$(THEOS_PACKAGE_SCHEME)"

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ifneq ($(THEOS_PACKAGE_ARCH),iphoneos-arm64)
# so this must be some older (pre 2023-03-26) Theos, need to mangle things a bit when packaging.

# for the filename and for the arch in before-stage::
THEOS_PACKAGE_ARCH = iphoneos-arm64

before-package::
# some backporting from makefiles/package/deb.mk post 2023-03-26 internal-package::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)"$(ECHO_END)
	$(ECHO_NOTHING)rsync -a "$(THEOS_STAGING_DIR)/" "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)" --exclude "DEBIAN" --exclude "$(THEOS_PACKAGE_INSTALL_PREFIX)" $(_THEOS_RSYNC_EXCLUDE_COMMANDLINE) $(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -mindepth 1 -maxdepth 1 ! -name DEBIAN ! -name "var" -exec rm -rf {} \;$(ECHO_END)
	$(ECHO_NOTHING)rmdir "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/var" >/dev/null 2>&1 || true$(ECHO_END)

endif
endif

before-stage::
	$(ECHO_NOTHING)sed -e 's/Architecture: iphoneos-arm.*/Architecture: $(THEOS_PACKAGE_ARCH)/' "$(THEOS_PROJECT_DIR)/control" > "$(THEOS_PROJECT_DIR)/control-$(THEOS_PACKAGE_SCHEME)"$(ECHO_END)

internal-stage::
	$(ECHO_NOTHING)find $(THEOS_STAGING_DIR) -name .DS_Store | xargs rm -rf$(ECHO_END)
	$(ECHO_NOTHING)find $(THEOS_STAGING_DIR) -name "*~" | xargs rm -f$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/OpenSshPort.plist$(ECHO_END)

after-package::
	$(ECHO_NOTHING)rm -f "$(THEOS_PROJECT_DIR)/control-$(THEOS_PACKAGE_SCHEME)" >/dev/null || true$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk

