{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;
  dmCfg = config.services.displayManager;

  defaultConfig =
    {
      LUKSUnlock.Greeter = lib.getExe' cfg.packages.sddm-minimal "sddm-greeter-qt6";
      LUKSUnlock.Devices = map (name: config.boot.initrd.luks.devices.${name}.device) cfg.luksDevices;
    }
    // (lib.optionalAttrs (cfg.theme.name != "") {
      Theme.Current = cfg.theme.name;
      Theme.ThemeDir = "${cfg.theme.themeEnv}/share/sddm/themes";
    })
    // (let
      stubbedSessions =
        pkgs.runCommandLocal "desktops-stubbed" {
          __structuredAttrs = true;
          unsafeDiscardReferences.out = true;
        } ''
          cp -rL ${dmCfg.sessionData.desktops} $out
          chmod -R u+w $out
          find $out -type f -exec sed -i "/^Exec=/d" {} \;
          find $out -type f -exec sed -i "s|Exec=.*|Exec=/proc/self/exe|" {} \;
        '';
    in
      lib.optionalAttrs dmCfg.enable {
        General.DefaultSession = lib.optionalString (dmCfg.defaultSession != null) "${dmCfg.defaultSession}.desktop";
        X11.SessionDir = "${stubbedSessions}/share/xsessions";
        Wayland.SessionDir = "${stubbedSessions}/share/wayland-sessions";
      });

  iniFmt = pkgs.formats.ini {listsAsDuplicateKeys = true;};
  sddmConfig = iniFmt.generate "initrd-sddm.conf" (lib.recursiveUpdate defaultConfig cfg.settings);

  glibcLocales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = ["C.UTF-8/UTF-8" "${cfg.locale}/UTF-8"];
  };
in {
  imports = [./squashed-closure.nix ./sddm-handoff.nix ./theming.nix];

  options.boot.initrd.luks.sddmUnlock = {
    enable = lib.mkEnableOption "LUKS unlock using SDDM in initrd";

    packages = lib.mkOption {
      type = lib.types.attrs;
      description = "The luks-stage1-sddm package scope to use";
      default = pkgs.luks-stage1-sddm;
      defaultText = lib.literalExpression "pkgs.luks-stage1-sddm";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Users which should be available to log in as.";
    };

    luksDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        The name of LUKS devices that will be unlocked using SDDM.
        There must be a corresponding entry in `boot.initrd.luks.devices` for each listed device.
      '';
    };

    locale = lib.mkOption {
      type = lib.types.str;
      description = "The locale used by the SDDM greeter.";
      default = config.i18n.defaultLocale;
      defaultText = lib.literalExpression "config.i18n.defaultLocale";
    };

    settings = lib.mkOption {
      type = iniFmt.type;
      description = "Extra settings merged in and overwriting defaults in sddm.conf.";
      default = {};
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd = {
      systemd = {
        #We need stage 1 systemd for any of this to work
        enable = true;

        #Setup the SDDM service
        services.luks-sddm = {
          description = "SDDM Graphical LUKS Unlock";

          after = ["systemd-sysctl.service" "systemd-udevd.service"];
          before = ["cryptsetup-pre.target" "systemd-ask-password-console.service"];
          wantedBy = ["cryptsetup.target"];
          unitConfig.DefaultDependencies = false;

          serviceConfig.Type = "notify";
          serviceConfig.ExecStart = "${lib.getExe cfg.packages.sddm-daemon} ${lib.escapeShellArg (toString sddmConfig)}";
          serviceConfig.KillMode = "mixed"; # - send SIGTERM only to the main process; required for a clean shutdown

          # - only attempt to start once (cryptsetup.target may have multiple start jobs queued)
          unitConfig.StartLimitBurst = 1;
          unitConfig.StartLimitIntervalSec = "infinity";

          # - if we fail, refresh the system's fbcon
          postStop = ''
            if [ "$SERVICE_RESULT" != "success" ]; then
              cat /sys/class/graphics/fbcon/rotate > /sys/class/graphics/fbcon/rotate
              systemctl try-restart systemd-ask-password-console.service
            fi
          '';

          environment = let
            xkb = config.services.xserver.xkb;
          in {
            # - configure the embedded QT backend
            QT_QPA_PLATFORM = "linuxfb";
            QT_QPA_PLATFORMTHEME = "generic";
            QT_QPA_FB_DRM = "1";

            # - configure the locale
            LC_ALL = cfg.locale;
            LOCALE_ARCHIVE = "${glibcLocales}/lib/locale/locale-archive";

            # - configure the keyboard layout
            XKB_DEFAULT_MODEL = xkb.model;
            XKB_DEFAULT_LAYOUT = xkb.layout;
            XKB_DEFAULT_OPTIONS = xkb.options;
            XKB_DEFAULT_VARIANT = xkb.variant;
          };
        };

        # - send a signal to the daemon once /sysroot was mounted so it may pivot
        services.luks-sddm-capture-sysroot = {
          description = "SDDM Graphical LUKS Unlock - /sysroot pivot";

          after = ["luks-sddm.service" "initrd-nixos-activation.service"];
          before = ["initrd-switch-root.service"];
          bindsTo = ["luks-sddm.service"];
          wantedBy = ["initrd-switch-root.target"];
          unitConfig.DefaultDependencies = false;

          serviceConfig.Type = "oneshot";
          script = "systemctl kill --signal=SIGUSR1 luks-sddm.service";
        };

        #Setup users we should be able to log in as
        users = lib.listToAttrs (lib.imap0
          (idx: name: {
            inherit name;
            value.uid = 10000 + idx; # - exact value doesn't matter
            value.group = "nogroup";
          })
          cfg.users);

        #Set the timezone (if configured)
        contents."/etc/localtime".source = lib.mkIf (config.time.timeZone != null) "${pkgs.tzdata}/share/zoneinfo/${config.time.timeZone}";
      };

      #We need to enable support for some things we need to have early in initrd
      supportedFilesystems = {
        squashfs = true;
        overlay = true;
      };

      availableKernelModules = ["evdev" "overlay"]; # - required for input / etc.

      #Configure the closure of things that are compressed / optionally sideloaded (handled in ./squashed-closure.nix)
      luks.sddmUnlock.closureContents = [glibcLocales cfg.packages.sddm-daemon sddmConfig];

      #Configure infinite retries for all devices we should unlock
      luks.devices = lib.genAttrs cfg.luksDevices (_: {crypttabExtraOpts = ["tries=0"];});
    };
  };
}
