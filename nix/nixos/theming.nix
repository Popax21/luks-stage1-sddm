{
  config,
  options,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;

  qt6-minimal = cfg.packages.qt6-minimal;
  qtPkgs = [qt6-minimal.qtdeclarative qt6-minimal.qtsvg] ++ (lib.optional cfg.theme.qt5Compat qt6-minimal.qt5compat);

  fontConf = let
    defaultCfg = name: fonts: ''
      <alias binding="same">
        <family>${name}</family>
        <prefer>
          ${lib.concatLines (map (f: "<family>${f}</family>") fonts)}
        </prefer>
      </alias>
    '';
  in
    pkgs.writeText "initrd-fontconfig.conf" ''
      <?xml version='1.0'?>
      <!DOCTYPE fontconfig SYSTEM 'urn:fontconfig:fonts.dtd'>
      <fontconfig>
        <include ignore_missing="yes">${pkgs.fontconfig.out}/conf.d</include>
        ${lib.concatLines (map (f: "<dir>${f}</dir>") cfg.theme.fontPackages)}
        ${lib.concatLines (lib.mapAttrsToList defaultCfg cfg.theme.defaultFonts)}
      </fontconfig>
    '';

  fontConfDir =
    if cfg.theme.fontPackages != []
    then
      pkgs.runCommand "initrd-fontconfig-dir" {} ''
        mkdir -p $out/conf.d

        FC=${pkgs.fontconfig.out}/etc/fonts
        sed 's|/etc/fonts/conf.d|'$out'/conf.d|;/<dir/d;/<cachedir/d' $FC/fonts.conf > $out/fonts.conf

        for f in $(ls $FC/conf.d); do
          cp $(readlink -f $FC/conf.d/$f) $out/conf.d/$f
        done

        cp ${fontConf} $out/conf.d/55-initrd-fontconfig.conf
      ''
    else null;

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
      default = [];
    };

    syncUserAvatars = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to copy user avatars into the initrd using the initrd secrets mechanism to be shown by the stage 1 SDDM greeter.";
      default = config.boot.loader.supportsInitrdSecrets;
    };

    fontPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      description = "Font packages to make available in the initrd environment.";
      default = [];
    };
    defaultFonts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      description = "Set the default font families to use for various font types.";
      default = {};
      example = {
        serif = ["Noto Serif"];
        sans-serif = ["Noto Sans"];
        monospace = ["Hack"];
        emoji = ["Noto Color Emoji"];
      };
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
    cursorHwAcceleration = lib.mkOption {
      type = lib.types.bool;
      description = "Whether or not to use hardware-accelerated for drawing the greeter cursor.";
      default = true;
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
      example = lib.literalExpression (lib.trim ''
        {
          "org.kde.ksvg" = pkgs.luks-stag1-sddm.kde-minimal.ksvg;
        }
      '');
    };

    envVars = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Environment variables to set for the SDDM greeter process.";
      default = {};
      example = {
        QT_QPA_SYSTEM_ICON_THEME = "breeze";
      };
    };

    extraPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Extra paths to include in the SDDM theme environment.";
      default = [];
      example = [
        "/share/plasma/desktoptheme/default"
        "/share/icons/breeze"
      ];
    };

    fixups = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      description = "A set of commands which are used to fix up files in the SDDM theme environment.";
      default = {};
      example = {
        "some/file" = "rm $target";
        "some/directory/" = "echo 'hi' >> $target";
      };
    };

    themeEnv = lib.mkOption {
      type = lib.types.package;
      internal = true;
    };
  };

  config = {
    #Build a theme environment containing the SDDM theme and all its referenced Qt QML modules
    boot.initrd.luks.sddmUnlock = {
      theme.themeEnv = pkgs.runCommand "initrd-sddm-theme-env" rec {
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

      theme.extraPaths = [
        "/share/locale/${lib.head (lib.splitString "_" cfg.locale)}"
        "/share/locale/${lib.head (lib.splitString "." cfg.locale)}"
        "/share/locale/${cfg.locale}"
      ];

      theme.envVars.FONTCONFIG_FILE = lib.mkIf (fontConfDir != null) "${fontConfDir}/fonts.conf";
      theme.envVars.QT_QPA_EGLFS_CURSOR = lib.mkIf (cursorAtlas != null) "${cursorAtlas}/config.json";

      extraClosureRules =
        [
          "!${cfg.theme.themeEnv}/"
        ]
        ++ (lib.optional (fontConfDir != null) "!${fontConfDir}/")
        ++ (lib.optional (cursorAtlas != null) "!${cursorAtlas}/")
        ++ (
          map (p: "!${cfg.theme.themeEnv}/${
            if lib.hasPrefix "/" p
            then lib.removePrefix "/" p
            else p
          }/")
          cfg.theme.extraPaths
        );
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
      closureContents =
        qtPkgs
        ++ (lib.optional (fontConfDir != null) fontConfDir)
        ++ (lib.optional (cursorAtlas != null) cursorAtlas);

      closureBuildDeps = [cfg.theme.themeEnv.raw] ++ (lib.attrValues cfg.theme.qmlModules);
    };

    #Copy user avatars (if enabled)
    system.build.initialRamdiskSecretAppender = lib.mkIf (cfg.enable && cfg.theme.syncUserAvatars) (
      let
        buildOpt = options.system.build;
        buildDefs = builtins.filter (d: d.file != (toString ./theming.nix)) buildOpt.definitionsWithLocations;
        buildVal = buildOpt.type.merge buildOpt.loc buildDefs;
      in
        lib.mkForce (pkgs.writeShellApplication {
          name = "append-initrd-secrets";
          text = ''
            export initrdUserAvatars=$(mktemp -d ''${TMPDIR:-/tmp}/initrd-user-avatars.XXXXXXXXXX)

            ${lib.concatLines (map
              (user: ''
                for path in ${lib.escapeShellArgs [
                  "${config.users.users.${user}.home}/.face.icon"
                  "/var/lib/AccountsService/icons/${user}"
                ]}; do
                  if [ -f "$path" ]; then
                    cp "$path" "$initrdUserAvatars/${user}"
                    echo "Copying user '${user}' avatar $path to initrd"
                    break
                  fi
                done
              '')
              cfg.users)}

            exec ${lib.getExe buildVal.initialRamdiskSecretAppender} "$@"
          '';
          runtimeInputs = [pkgs.coreutils];
        })
    );
    boot.initrd.secrets."/var/lib/AccountsService/icons" = lib.mkIf (cfg.enable && cfg.theme.syncUserAvatars) "/$initrdUserAvatars"; # :p
  };
}
