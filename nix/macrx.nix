# macrx built with the host's Xcode Command Line Tools: it needs Swift 6 and the macOS 14+ SDK
# (AppKit), which nixpkgs' Swift (5.10, no AppKit) can't provide. So this is impure — it runs
# /usr/bin/swift and /usr/bin/codesign — and needs `sandbox = false`, nix-darwin's default.
# TOMLKit, the only dependency, is fetched by Nix at the revision Package.resolved pins and
# handed to SwiftPM as a local package, so the build itself needs no network.
{
  lib,
  stdenvNoCC,
  fetchgit,
  src,
}:
let
  pins = (lib.importJSON (src + "/Package.resolved")).pins;
  pin = lib.findFirst (
    p: p.identity == "tomlkit"
  ) (throw "TOMLKit missing from Package.resolved") pins;
  tomlkit = fetchgit {
    url = pin.location;
    rev = pin.state.revision;
    # Update when Package.resolved moves TOMLKit (`nix build` prints the new hash).
    hash = "sha256-1aSH9Ze9rkk0EEDNoBlc/B6iXRmMx98ySOqhpfvQY2I=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "macrx";
  version = "0-unstable-${src.shortRev or src.dirtyShortRev or "dirty"}";
  inherit src;

  postPatch = ''
    # SwiftPM names a path dependency after its directory, so give it its real name.
    cp -r ${tomlkit} ../TOMLKit
    chmod -R u+w ../TOMLKit
    substituteInPlace Package.swift \
      --replace-fail '.package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0")' \
                     '.package(path: "../TOMLKit")'
    rm -f Package.resolved
  '';

  buildPhase = ''
    runHook preBuild
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    # The build user has no writable home: keep SwiftPM's caches in the build directory.
    /usr/bin/swift build -c release --disable-sandbox \
      --scratch-path "$TMPDIR/build" \
      --cache-path "$TMPDIR/cache" --config-path "$TMPDIR/config" --security-path "$TMPDIR/security"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$TMPDIR/build/release/macrx" -t $out/bin
    runHook postInstall
  '';

  # Same identifier the Justfile signs with. Ad hoc, though: macOS keys the Accessibility grant
  # on the signature, so each new build asks for it again.
  postFixup = ''
    /usr/bin/codesign --force -s - --identifier dev.macrx.macrx $out/bin/macrx
  '';

  meta = {
    description = "Keyboard-driven tiling window manager for macOS";
    homepage = "https://github.com/wesalvaro/macrx";
    platforms = lib.platforms.darwin;
    mainProgram = "macrx";
  };
}
