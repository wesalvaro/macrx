# nix-darwin module: macrx as a launchd user agent (label org.nixos.macrx; what `just install`
# sets up by hand as dev.macrx.macrx — run `just uninstall` first if that one is loaded).
#
# macrx needs Accessibility access (System Settings → Privacy & Security → Accessibility) and
# waits until it is granted; macOS ties the grant to the binary's signature, so each new build
# asks again. Config: ~/.config/macrx/config.toml (and rules.toml for rules added from the UI).
# Log: /tmp/macrx.log.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.macrx;
in
{
  options.services.macrx = {
    enable = lib.mkEnableOption "macrx, a tiling window manager, as a launchd user agent";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.macrx;
      defaultText = lib.literalExpression "macrx.packages.\${system}.macrx";
      description = "The macrx build to run.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    launchd.user.agents.macrx = {
      command = lib.getExe cfg.package;
      serviceConfig = {
        KeepAlive = true;
        RunAtLoad = true;
        # Needs the user's WindowServer session (Accessibility, the tab bars, the menu bar item).
        ProcessType = "Interactive";
        EnvironmentVariables.LANG = "en_US.UTF-8";
        StandardOutPath = "/tmp/macrx.log";
        StandardErrorPath = "/tmp/macrx.log";
      };
    };
  };
}
