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

  squashedClosure = pkgs.stdenvNoCC.mkDerivation {
    name = "initrd-sddm-closure";

    __structuredAttrs = true;
    exportReferencesGraph.closure = [cfg.package sddmConfig];
    unsafeDiscardReferences.out = true;

    nativeBuildInputs = with pkgs; [jq squashfsTools];

    buildCommand = ''jq -r '.closure[].path' < "$NIX_ATTRS_JSON_FILE" | xargs mksquashfs {} "$out" -comp xz'';
  };
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
      storePaths = [squashedClosure pkgs.mount];

      services.luks-sddm = {
        description = "SDDM Graphical LUKS Unlock";
        before = ["cryptsetup-pre.target"];
        requiredBy = ["sysinit.target"];
        requires = ["luks-sddm-overlay.mount"];
        serviceConfig.ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArg (toString sddmConfig)}";
        preStart = ''
          mkdir -p /tmp/luks-sddm-squash
          ${lib.getExe pkgs.mount} -t squashfs -o loop ${squashedClosure} /tmp/luks-sddm-squash
          ${lib.getExe pkgs.mount} -t overlay overlay -o lowerdir=${builtins.storeDir}:/tmp-luks-sddm-squash ${builtins.storeDir}
        '';
      };
    };
  };
}
