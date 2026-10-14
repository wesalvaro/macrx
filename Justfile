fw := "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
plugins := "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
testlib := "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
# Command Line Tools ship Swift Testing but SwiftPM does not find it on its own.
test_flags := "--disable-xctest --enable-swift-testing -Xswiftc -F" + fw + " -Xswiftc -plugin-path -Xswiftc " + plugins + " -Xlinker -F" + fw + " -Xlinker -rpath -Xlinker " + fw + " -Xlinker -rpath -Xlinker " + testlib
bin := ".build/debug/macrx"
identity := "macrx-dev"

build:
    swift build

test:
    swift test {{test_flags}}

sign: build
    @if security find-identity -v -p codesigning | grep -q "{{identity}}"; then \
      codesign --force --sign "{{identity}}" --identifier dev.macrx.macrx {{bin}}; \
    else \
      echo "warning: no '{{identity}}' identity; run 'just dev-cert' so Accessibility grants survive rebuilds"; \
    fi

run: sign
    {{bin}}

dev-cert:
    scripts/dev-cert.sh {{identity}}

clean:
    rm -rf .build
