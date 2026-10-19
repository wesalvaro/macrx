fw := "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
plugins := "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
testlib := "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
# Command Line Tools ship Swift Testing but SwiftPM does not find it on its own.
test_flags := "--disable-xctest --enable-swift-testing -Xswiftc -F" + fw + " -Xswiftc -plugin-path -Xswiftc " + plugins + " -Xlinker -F" + fw + " -Xlinker -rpath -Xlinker " + fw + " -Xlinker -rpath -Xlinker " + testlib
bin := ".build/debug/macrx"
identity := "macrx-dev"
label := "dev.macrx.macrx"
domain := "gui/" + `id -u`

build:
    swift build

test:
    swift test {{test_flags}}

sign: build
    @if security find-identity -v -p codesigning | grep -q "{{identity}}"; then \
      codesign --force --sign "{{identity}}" --identifier {{label}} {{bin}}; \
    else \
      echo "warning: no '{{identity}}' identity; run 'just dev-cert' so Accessibility grants survive rebuilds"; \
    fi

# Foreground, for development. Stop the agent first if it is installed.
run: sign
    {{bin}}

dev-cert:
    scripts/dev-cert.sh {{identity}}

# Build, sign and install/update the launchd agent (~/.local/bin/macrx, starts at login).
install: sign
    scripts/install-agent.sh {{bin}}

# Restart the installed agent without rebuilding.
restart:
    launchctl kickstart -k {{domain}}/{{label}}

stop:
    launchctl bootout {{domain}}/{{label}}

uninstall:
    -launchctl bootout {{domain}}/{{label}}
    rm -f ~/Library/LaunchAgents/{{label}}.plist ~/.local/bin/macrx

status:
    @launchctl print {{domain}}/{{label}} 2>/dev/null | grep -E "state|pid|last exit" || echo "{{label}} is not loaded"

logs:
    tail -f /tmp/macrx.log

clean:
    rm -rf .build
