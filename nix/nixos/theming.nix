{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;

  qt6-minimal = cfg.packages.qt6-minimal;
  qtPkgs = [qt6-minimal.qtdeclarative qt6-minimal.qtsvg] ++ (lib.optional cfg.theme.qt5Compat qt6-minimal.qt5compat);

  cursorAtlas =
    if cfg.theme.cursorIcons != null
    then
      pkgs.runCommand "initrd-sddm-cursor-atlas" {
        nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.pillow])) pkgs.xcur2png];
      } "python3 ${./build-cursor-atlas.py} ${cfg.theme.themeEnv.rawEnv} ${cfg.theme.cursorIcons} ${toString cfg.theme.cursorSize}"
    else null;
in {
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

    cursorIcons = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The icon set to use for the mouse cursor, or `null` for the default Qt cursors.";
      default = null;
    };
    cursorSize = lib.mkOption {
      type = lib.types.int;
      description = "The size of cursor to use in pixels.";
      default = builtins.ceil (32 * (cfg.displayDpi / 96.0));
    };

    syncUserAvatars = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to copy user avatars into the initrd using the initrd secrets mechanism to be shown by the stage 1 SDDM greeter.";
      default = config.boot.loader.supportsInitrdSecrets;
    };

    qtSwRendering = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Use Qt Quick's software rendering backend instead of a OpenGL ES / Mesa3D llvmpipe-backed renderer.
        Can reduce the SDDM closure size, but may result in reduced graphical fidelity.
        Does not support multiple monitors, and will always render to a single output (which may be selected using `QT_QPA_EGLFS_KMS_CONNECTOR_INDEX`).
      '';
      default = false;
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
          "org.kde.ksvg" = pkgs.luks-stag1-sddm.kde-minimal.ksvg;
        }
      '';
    };

    envVars = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Environment variables to set for the SDDM greeter process.";
      default = {};
      example = ''
        {
          QT_QPA_SYSTEM_ICON_THEME = "breeze";
        }
      '';
    };

    extraPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Extra paths to include in the SDDM theme environment.";
      default = [];
      example = ''
        [
          "/share/plasma/desktoptheme/default"
          "/share/icons/breeze"
        ]
      '';
    };
    extraClosureRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Extra exclusion rules to apply when building the initrd closure.";
      default = [];
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

  config = {
    #Build a theme environment containing the SDDM theme and all its referenced Qt QML modules
    boot.initrd.luks.sddmUnlock.theme = {
      themeEnv = pkgs.runCommand "initrd-sddm-theme-env" rec {
        __structuredAttrs = true;
        nativeBuildInputs = with pkgs; [python3];

        # - build a raw theme env first which we then trim down into a
        rawEnv = pkgs.buildEnv {
          name = "initrd-sddm-theme-env-raw";
          paths = cfg.theme.packages;
          includeClosures = true;

          pathsToLink =
            [
              "/lib/qt-6"
              "/share/sddm/themes/${cfg.theme.name}"
            ]
            ++ (lib.optional (cfg.theme.cursorIcons != null) "/share/icons/${cfg.theme.cursorIcons}")
            ++ cfg.theme.extraPaths;
        };
        passthru.raw = rawEnv;

        inherit (cfg.theme) qmlModules fixups extraPaths;
      } "python3 ${./build-theme-env.py}";

      extraPaths = [
        "/share/locale/${lib.head (lib.splitString "_" cfg.locale)}"
        "/share/locale/${lib.head (lib.splitString "." cfg.locale)}"
        "/share/locale/${cfg.locale}"
      ];

      extraClosureRules =
        [
          "!${cfg.theme.themeEnv}/lib/qt-6/"
        ]
        ++ (lib.optional (cfg.theme.cursorIcons != null) "!${cursorAtlas}/")
        ++ (
          map (p: "!${cfg.theme.themeEnv}/${
            if lib.hasPrefix "/" p
            then lib.removePrefix "/" p
            else p
          }/")
          cfg.theme.extraPaths
        );

      envVars.QT_QPA_EGLFS_CURSOR = lib.mkIf (cursorAtlas != null) "${cursorAtlas}/config.json";
    };

    #Hook up theme Qt modules / plugins
    boot.initrd.systemd.services.luks-sddm.environment =
      cfg.theme.envVars
      // {
        XDG_DATA_DIRS = lib.makeSearchPath "share" ([cfg.theme.themeEnv] ++ qtPkgs);

        QT_PLUGIN_PATH = lib.makeSearchPath "lib/qt-6/plugins" ([cfg.theme.themeEnv] ++ qtPkgs);
        QML_IMPORT_PATH = lib.makeSearchPath "lib/qt-6/qml" ([cfg.theme.themeEnv] ++ qtPkgs);
      };

    boot.initrd.luks.sddmUnlock = {
      closureContents = qtPkgs ++ (lib.optional (cursorAtlas != null) cursorAtlas);
      closureBuildDeps = [cfg.theme.themeEnv.raw] ++ (lib.attrValues cfg.theme.qmlModules);
    };

    #Copy user avatars (if enabled)
    boot.initrd.secrets = lib.mkIf cfg.theme.syncUserAvatars (lib.genAttrs' cfg.users (u: lib.nameValuePair "/var/lib/AccountsService/users/${u}" null));
  };
}
