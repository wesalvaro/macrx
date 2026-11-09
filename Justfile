fw := "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
plugins := "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
testlib := "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
# Command Line Tools ship Swift Testing but SwiftPM does not find it on its own.
test_flags := "--disable-xctest --enable-swift-testing -Xswiftc -F" + fw + " -Xswiftc -plugin-path -Xswiftc " + plugins + " -Xlinker -F" + fw + " -Xlinker -rpath -Xlinker " + fw + " -Xlinker -rpath -Xlinker " + testlib
bin := ".build/debug/macrx"
identity := "macrx-dev"
identifier := "dev.macrx.macrx"
agent := "org.nixos.macrx"
plist := "~/Library/LaunchAgents/" + agent + ".plist"
domain := "gui/" + `id -u`

build:
    swift build

test:
    swift test {{test_flags}}

sign: build
    @if security find-identity -v -p codesigning | grep -q "{{identity}}"; then \
      codesign --force --sign "{{identity}}" --identifier {{identifier}} {{bin}}; \
    else \
      echo "warning: no '{{identity}}' identity; run 'just dev-cert' so Accessibility grants survive rebuilds"; \
    fi

# Stop the launchd agent (and any running dev instance) and wait for it to exit.
stop:
    -launchctl bootout {{domain}}/{{agent}} 2>/dev/null
    -pkill -x macrx 2>/dev/null
    @for _ in $(seq 1 50); do pgrep -x macrx >/dev/null || break; sleep 0.1; done

# Shut down the real binary and switch to the local dev binary in the background.
dev: sign stop
    @/usr/bin/perl -MPOSIX -e 'fork and exit; POSIX::setsid(); open STDIN, "</dev/null"; open STDOUT, ">>/tmp/macrx.log"; open STDERR, ">&STDOUT"; exec @ARGV' {{bin}}
    @sleep 0.2
    @just status

# Shut down the real binary and run the local dev binary in the foreground.
run: sign stop
    {{bin}}

# Stop any dev instance and start/restart the real launchd agent (org.nixos.macrx).
restart: stop
    launchctl bootstrap {{domain}} {{plist}}

dev-cert:
    scripts/dev-cert.sh {{identity}}

status:
    @ps -o pid,lstart,command -p $(pgrep -d, -x macrx) 2>/dev/null || echo "macrx is not running"

logs:
    tail -f /tmp/macrx.log

clean:
    rm -rf .build

# Nix: the flake builds the same binary with the host's toolchain (see nix/macrx.nix).
nix-build:
    nix build .#macrx -L

# Build and push to cachix so other machines get the binary. Needs a one-time `cachix authtoken`.
push: nix-build
    nix run nixpkgs#cachix -- push macrx ./result
