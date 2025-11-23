{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;

  iniFmt = pkgs.formats.ini {};

  defaultConfig = {
    General.DisplayServer = "wayland";
    Theme.Current = cfg.theme;
  };

  sddmConfig = iniFmt.generate "initrd-sddm.conf" (lib.recursiveUpdate defaultConfig cfg.settings);
in {
  options.boot.initrd.luks.sddmUnlock = {
    enable = lib.mkEnableOption "LUKS unlock using SDDM in initrd";
    package = lib.mkPackageOption pkgs "luks-stage1-sddm" {};

    theme = lib.mkOption {
      type = lib.types.str;
      default = config.services.displayManager.sddm.theme;
      defaultText = lib.literalExpression "config.services.displayManager.sddm.theme";
      description = "Greeter theme to use.";
    };

    settings = lib.mkOption {
      type = iniFmt.type;
      description = "Extra settings merged in and overwriting defaults in sddm.conf.";
      default = {};
    };
  };
  config = lib.mkIf cfg.enable {
    boot.initrd.systemd = {
      enable = true;
      storePaths = [cfg.package sddmConfig];
      services.luks-sddm = {
        description = "SDDM Graphical LUKS Unlock";
        before = ["cryptsetup-pre.target"];
        requiredBy = ["sysinit.target"];
        serviceConfig.ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArg (toString sddmConfig)}";
      };
    };
  };
}
