FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TESTLIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
# Command Line Tools ship Swift Testing but SwiftPM does not find it on its own.
TEST_FLAGS := --disable-xctest --enable-swift-testing \
  -Xswiftc -F$(FW) -Xswiftc -plugin-path -Xswiftc $(PLUGINS) \
  -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(TESTLIB)
BIN := .build/debug/macrx
IDENTITY := macrx-dev

.PHONY: build test run sign dev-cert clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

sign: build
	@if security find-identity -v -p codesigning | grep -q "$(IDENTITY)"; then \
	  codesign --force --sign "$(IDENTITY)" --identifier dev.macrx.macrx $(BIN); \
	else \
	  echo "warning: no '$(IDENTITY)' identity; run 'make dev-cert' so Accessibility grants survive rebuilds"; \
	fi

run: sign
	$(BIN)

dev-cert:
	scripts/dev-cert.sh $(IDENTITY)

clean:
	rm -rf .build
