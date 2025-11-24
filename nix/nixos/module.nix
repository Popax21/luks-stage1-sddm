{
  config,
  options,
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

  squashedClosurePath = "/luks-sddm-closure.sqsh";
  squashedClosure =
    pkgs.runCommand "initrd-sddm-closure" {
      __structuredAttrs = true;
      exportReferencesGraph.closure = [cfg.package sddmConfig];
      unsafeDiscardReferences.out = true;

      basePaths = let
        defs = lib.flatten (lib.options.getValues options.boot.initrd.systemd.storePaths.definitionsWithLocations);

        filterDefs = d: builtins.typeOf d != "set" || (d.target or null) != squashedClosurePath;

        defToStorePath = d:
          toString (
            if builtins.typeOf d == "set"
            then d.outPath or d.source
            else d
          );
      in
        map defToStorePath (builtins.filter filterDefs defs);

      nativeBuildInputs = with pkgs; [jq squashfsTools];
    } ''
      mapfile -t closure < <(cat "$NIX_ATTRS_JSON_FILE" | jq -r '.closure[].path' | xargs -i find {} -type f -or -type l | sort -u)
      mapfile -t basePaths < <(cat "$NIX_ATTRS_JSON_FILE" | jq -r '.basePaths[]' | xargs -i find {} -type f -or -type l | sort -u)

      mapfile -t commonPaths < <((IFS=$'\n'; echo "''${closure[*]}"; echo "''${basePaths[*]}") | sort | uniq -d)
      mapfile -t toCompress < <((IFS=$'\n'; echo "''${closure[*]}"; echo "''${commonPaths[*]}") | sort | uniq -u)

      echo "Compressing ''${#toCompress[@]} files (''${#closure[@]} total, skipping ''${#commonPaths[@]} common files)"
      (IFS=$'\n'; echo "''${toCompress[*]}") | mksquashfs - "$out" -quiet -no-strip -cpiostyle -comp xz
    '';
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

      storePaths = [
        {
          source = squashedClosure;
          target = squashedClosurePath;
        }
      ];

      services.luks-sddm = {
        description = "SDDM Graphical LUKS Unlock";
        after = ["systemd-sysctl.service" "systemd-udevd.service" "localfs.target"];
        before = ["cryptsetup-pre.target"];
        wantedBy = ["cryptsetup.target"];
        unitConfig.DefaultDependencies = false;

        preStart = ''
          mkdir -p /tmp/luks-sddm-closure
          mount -t squashfs -o loop ${lib.escapeShellArg squashedClosurePath} /tmp/luks-sddm-closure
          mount -t overlay overlay -o lowerdir=${builtins.storeDir}:/tmp/luks-sddm-closure${builtins.storeDir} ${builtins.storeDir}
        '';
        serviceConfig.ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArg (toString sddmConfig)}";
      };
    };
    boot.initrd.supportedFilesystems.squashfs = true;
  };
}
