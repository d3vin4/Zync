# Zync — Makefile (pure clang, no Theos)
# Usage: make            → build/libZync.dylib (arm64, min iOS 15.1)
#        make gates      → static verification of the artifact
#        make clean

ARCH      := arm64
PLATFORM  := iphoneos
MIN_IOS   := 15.1
SRC_DIR   := Sources
BUILD_DIR := build
TARGET    := $(BUILD_DIR)/libZync.dylib

SDKROOT := $(shell xcrun --sdk $(PLATFORM) --show-sdk-path)

SOURCES := $(wildcard $(SRC_DIR)/*.m)

CFLAGS := -arch $(ARCH) \
          -isysroot $(SDKROOT) \
          -miphoneos-version-min=$(MIN_IOS) \
          -fobjc-arc -fmodules -fblocks \
          -O2 -Wall -Wextra -Wno-unused-parameter \
          -install_name @executable_path/Frameworks/libZync.dylib

FRAMEWORKS := -framework UIKit -framework Foundation -framework QuartzCore

all: $(TARGET)

$(TARGET): $(SOURCES) $(SRC_DIR)/Zync.h
	@mkdir -p $(BUILD_DIR)
	xcrun --sdk $(PLATFORM) clang -dynamiclib $(CFLAGS) $(FRAMEWORKS) -o $(TARGET) $(SOURCES)
	xcrun codesign --force --sign - --timestamp=none $(TARGET)
	@echo "built $(TARGET)"

gates: $(TARGET)
	./Scripts/gates.sh

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all gates clean
