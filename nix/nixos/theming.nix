{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [./breeze-fixups.nix];

  options.boot.initrd.luks.sddmUnlock.theme = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Greeter theme to use.";
      default = config.services.displayManager.sddm.theme;
      defaultText = lib.literalExpression "config.services.displayManager.sddm.theme";
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      description = "Extra SDDM themes / Qt plugins / QML libraries to add to the initrd environment.";
      default = config.services.displayManager.sddm.extraPackages;
      defaultText = lib.literalExpression "config.services.displayManager.sddm.extraPackages";
    };

    qt5Compat = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to enable support for the `Qt5Compat` QML modules within the SDDM theme environment.";
      default = false;
    };
    qmlModules = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      description = "A set of initrd-suitable QML modules which are used to replace existing ones in the SDDM theme environment.";
      default = {};
      example = ''
        {
          "org.kde.ksvg" = pkgs.luks-stag1-sddm.qt6-minimal.replaceQtPkgs pkgs.kdePackages.ksvg;
        }
      '';
    };
    fixups = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      description = "A set of commands which are used to fix up files in the SDDM theme environment.";
      default = {};
      example = ''
        {
          "some/file" = "rm $target";
          "some/directory/" = "echo 'hi' >> $target";
        }
      '';
    };

    themeEnv = lib.mkOption {
      type = lib.types.package;
      internal = true;
    };
  };

  config = let
    cfg = config.boot.initrd.luks.sddmUnlock;
    qt6-minimal = cfg.packages.qt6-minimal;
  in {
    #Build a theme environment containing the SDDM theme and all its referenced Qt QML modules
    boot.initrd.luks.sddmUnlock.theme.themeEnv = pkgs.runCommand "initrd-sddm-theme-env" rec {
      __structuredAttrs = true;
      nativeBuildInputs = with pkgs; [python3];

      # - build a raw theme env first which we then trim down into a
      rawEnv = pkgs.buildEnv {
        name = "initrd-sddm-theme-env-raw";
        paths = cfg.theme.packages;
        includeClosures = true;

        pathsToLink = [
          "/lib/qt-6"
          "/share/sddm/themes/${cfg.theme.name}"
        ];
      };
      passthru.raw = rawEnv;

      inherit (cfg.theme) qmlModules fixups;
    } "python3 ${./build-theme-env.py}";

    #Hook up theme Qt modules / plugins
    boot.initrd.systemd.services.luks-sddm.environment = let
      qtPkgs = [cfg.theme.themeEnv qt6-minimal.qtdeclarative] ++ (lib.optional cfg.theme.qt5Compat qt6-minimal.qt5compat);
    in {
      QT_PLUGIN_PATH = lib.makeSearchPath "lib/qt-6/plugins" qtPkgs;
      QML_IMPORT_PATH = lib.makeSearchPath "lib/qt-6/qml" qtPkgs;
    };

    boot.initrd.luks.sddmUnlock = {
      closureContents = lib.mkIf cfg.theme.qt5Compat [qt6-minimal.qt5compat];
      closureBuildDeps = [cfg.theme.themeEnv.raw] ++ (lib.attrValues cfg.theme.qmlModules);
    };
  };
}
