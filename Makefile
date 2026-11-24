CC := clang
BUILD_DIR := build
NATIVE_DIR := native/kbm_bridge
CHIAKI_DYLIB := $(BUILD_DIR)/libsenza_chiaki.dylib
SONY_DYLIB := $(BUILD_DIR)/libsenza_sony.dylib
TEST_BIN := $(BUILD_DIR)/test_mapper_core
APP_BUNDLE := $(BUILD_DIR)/Senza.app
PREFIX ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin

CFLAGS := -O2 -Wall -Wextra -std=c11 -I$(NATIVE_DIR)
OBJCFLAGS := -O2 -Wall -Wextra -fobjc-arc -I$(NATIVE_DIR)
FRAMEWORKS := -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices -framework Cocoa -framework QuartzCore -framework GameController -framework CoreHaptics
SONY_FRAMEWORKS := $(FRAMEWORKS) -framework IOKit

.PHONY: all build app install install-app uninstall test test-c test-py clean

all: build

build: $(CHIAKI_DYLIB) $(SONY_DYLIB)

$(CHIAKI_DYLIB): \
	$(NATIVE_DIR)/mapper_core.c \
	$(NATIVE_DIR)/config_loader.c \
	$(NATIVE_DIR)/macos_capture.m \
	$(NATIVE_DIR)/sdl_virtual_pad.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -fPIC -c $(NATIVE_DIR)/mapper_core.c -o $(BUILD_DIR)/mapper_core.o
	$(CC) $(CFLAGS) -fPIC -c $(NATIVE_DIR)/config_loader.c -o $(BUILD_DIR)/config_loader.o
	$(CC) $(OBJCFLAGS) -fPIC -c $(NATIVE_DIR)/macos_capture.m -o $(BUILD_DIR)/macos_capture.o
	$(CC) $(CFLAGS) -fPIC -c $(NATIVE_DIR)/sdl_virtual_pad.c -o $(BUILD_DIR)/sdl_virtual_pad.o
	$(CC) -dynamiclib -Wl,-undefined,dynamic_lookup \
		$(BUILD_DIR)/mapper_core.o \
		$(BUILD_DIR)/config_loader.o \
		$(BUILD_DIR)/macos_capture.o \
		$(BUILD_DIR)/sdl_virtual_pad.o \
		-o $(CHIAKI_DYLIB) $(FRAMEWORKS) -lm
	codesign --force --sign - $(CHIAKI_DYLIB)

$(SONY_DYLIB): \
	$(NATIVE_DIR)/mapper_core.c \
	$(NATIVE_DIR)/config_loader.c \
	$(NATIVE_DIR)/macos_capture.m \
	$(NATIVE_DIR)/iokit_dualsense_pad.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -fPIC -c $(NATIVE_DIR)/mapper_core.c -o $(BUILD_DIR)/mapper_core.o
	$(CC) $(CFLAGS) -fPIC -c $(NATIVE_DIR)/config_loader.c -o $(BUILD_DIR)/config_loader.o
	$(CC) $(OBJCFLAGS) -fPIC -c $(NATIVE_DIR)/macos_capture.m -o $(BUILD_DIR)/macos_capture.o
	$(CC) $(CFLAGS) -fPIC -c $(NATIVE_DIR)/iokit_dualsense_pad.c -o $(BUILD_DIR)/iokit_dualsense_pad.o
	$(CC) -dynamiclib -Wl,-undefined,dynamic_lookup \
		$(BUILD_DIR)/mapper_core.o \
		$(BUILD_DIR)/config_loader.o \
		$(BUILD_DIR)/macos_capture.o \
		$(BUILD_DIR)/iokit_dualsense_pad.o \
		-o $(SONY_DYLIB) $(SONY_FRAMEWORKS) -lm
	codesign --force --sign - $(SONY_DYLIB)

app: build
	bash scripts/build_app.sh "$(APP_BUNDLE)"

install: build app
	mkdir -p "$(BIN_DIR)"
	chmod +x "$(CURDIR)/bin/senza"
	ln -sf "$(CURDIR)/bin/senza" "$(BIN_DIR)/senza"
	@echo "Installed CLI: $(BIN_DIR)/senza -> $(CURDIR)/bin/senza"
	@echo "App launcher : $(CURDIR)/$(APP_BUNDLE)"
	@echo 'Next step    : senza setup  (or "make install-app" to copy Senza.app to /Applications)'

install-app: app
	rm -rf "/Applications/Senza.app"
	cp -R "$(APP_BUNDLE)" "/Applications/Senza.app"
	@echo "Installed GUI app: /Applications/Senza.app"

uninstall:
	rm -f "$(BIN_DIR)/senza"
	@echo "Removed $(BIN_DIR)/senza"

$(TEST_BIN): $(NATIVE_DIR)/mapper_core.c $(NATIVE_DIR)/config_loader.c tests/test_mapper_core.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE_DIR)/mapper_core.c $(NATIVE_DIR)/config_loader.c tests/test_mapper_core.c -o $(TEST_BIN) -lm

test-c: $(TEST_BIN)
	./$(TEST_BIN)

test-py:
	python3 -m unittest discover -s tests -p "test_*.py" -v

test: test-c test-py

clean:
	rm -rf $(BUILD_DIR)
