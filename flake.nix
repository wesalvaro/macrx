{
  description = "macrx: a keyboard-driven tiling window manager for macOS";

  # Binary cache for the build (pushed with `just push`). Nix asks once whether to trust these;
  # a consuming config can set the same in nix.settings so no prompt appears.
  nixConfig = {
    extra-substituters = [ "https://macrx.cachix.org" ];
    extra-trusted-public-keys = [
      "macrx.cachix.org-1:n8bg2JamigaihEZrob+Fa2kKxpSk2wlB5CBQR8lyDsY="
    ];
  };

  inputs = {
    # Pinned on purpose: the cachix binaries are built against exactly this revision, so
    # consumers should not `follows` it.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      eachSystem = f: lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = eachSystem (pkgs: rec {
        macrx = pkgs.callPackage ./nix/macrx.nix { src = self; };
        default = macrx;
      });

      # `nix run github:wesalvaro/macrx` for ad-hoc foreground use (stop any installed agent first).
      apps = eachSystem (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.macrx;
        };
      });

      # nix-darwin: `services.macrx.enable = true` runs macrx as a launchd user agent.
      darwinModules.default = import ./nix/darwin-module.nix { inherit self; };

      formatter = eachSystem (pkgs: pkgs.nixfmt-tree);
    };
}
