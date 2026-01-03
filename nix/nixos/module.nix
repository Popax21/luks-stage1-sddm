{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;
  dmCfg = config.services.displayManager;

  glibcLocales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = ["C.UTF-8/UTF-8" "${cfg.locale}/UTF-8"];
  };

  kmsConfig = pkgs.writeText "initrd-kms-config.json" (builtins.toJSON {
    device = cfg.driDevice;
    hwcursor = cfg.theme.cursorHwAcceleration;
    outputs =
      lib.mapAttrsToList (name: cfg: (lib.filterAttrs (_: v: v != null) {
        inherit name;
        inherit (cfg) mode virtualIndex;
        virtualPos =
          if cfg.virtualPos != null
          then "${cfg.virtualPos.x},${cfg.virtualPos.y}"
          else null;
      }))
      cfg.displayOutputs;
  });

  kmsModuleClosure =
    if cfg.kmsModules != [] || cfg.availableKmsModules != []
    then
      (pkgs.makeModulesClosure {
        rootModules = lib.concatLists [
          cfg.kmsModules
          cfg.availableKmsModules
          # - also include the baseline modules to ensure our depmod output doesn't hide any modules
          config.boot.initrd.kernelModules
          config.boot.initrd.availableKernelModules
        ];
        kernel = config.system.modulesTree;
        firmware = config.hardware.firmware;
        allowMissing = config.boot.initrd.allowMissingModules;
        inherit (config.boot.initrd) extraFirmwarePaths;
      }).overrideAttrs (old: {
        builder = pkgs.writeShellScript "initrd-kms-module-closure-builder" ''
          source ${old.builder}

          export CLOSURE=${config.system.build.modulesClosure}
          find $CLOSURE -path '**/kernel/**' -type f -exec sh -c 'rm $out/$(realpath --relative-to=$CLOSURE {})' \;
        '';
      })
    else null;

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

    syncPasswordChanges = lib.mkOption {
      type = lib.types.bool;
      description = "Change the LUKS password when the password of an early-logon user gets changed.";
      default = true;
    };

    kmsModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Kernel modules to explicitly load for enabling KMS support. These kernel modules will be stored in the squashed closure.";
      default = [];
      example = ["nvidia"];
    };
    availableKmsModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Kernel modules to make available for enabling KMS support. These kernel modules will be stored in the squashed closure.";
      default = [];
      example = ["amdgpu"];
    };

    displayOutputs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          mode = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            description = "The output mode to set the screen to.";
            default = null;
            example = lib.literalExpression ''"1920x1080" # or: "off", "current", "preferred", "skip", "1920x1080@60", ...'';
          };

          virtualIndex = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            description = "The index of the screen in the virtual desktop. Screens are arranged from left-to-right in order of ascending virtual indices.";
            default = null;
          };

          virtualPos = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              option.x = lib.mkOption {
                type = lib.types.int;
                description = "The X coordinate of the screen on the virtual desktop.";
              };
              option.y = lib.mkOption {
                type = lib.types.int;
                description = "The Y coordinate of the screen on the virtual desktop.";
              };
            });
            description = "The position of the screen on the virtual desktop. This can be used to override the default positioning logic based on `virtualIndex`.";
            default = null;
          };
        };
      });
      description = "Configuration of output display to use with SDDM. Screens are arranged in a virtual desktop-like layout.";
      default = {};
    };
    displayDpi = lib.mkOption {
      type = lib.types.ints.positive;
      description = "The DPI of the output display. Note that DPI may not be specified per-screen, and must be identical when multiple monitors are in-use.";
      default = 96;
    };
    driDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The DRI device to use. If not specified, a DRI device is picked automatically.";
      default = null;
      example = "/dev/dri/card2";
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
    assertions = [
      {
        assertion = cfg.users != [];
        message = "`boot.initrd.luks.sddmUnlock.users` needs to contain at least one user for LUKS stage 1 SDDM unlocking to be enabled.";
      }
    ];

    boot.initrd = {
      systemd = {
        #We need stage 1 systemd for any of this to work
        enable = true;

        #Setup the SDDM service
        services.luks-sddm = {
          description = "SDDM Graphical LUKS Unlock";

          after = ["systemd-modules-load.service" "systemd-sysctl.service" "systemd-udevd.service"];
          before = ["cryptsetup-pre.target" "systemd-ask-password-console.service"];
          wantedBy = ["cryptsetup.target"];
          unitConfig.DefaultDependencies = false;

          serviceConfig.Type = "notify";
          serviceConfig.ExecStart = "${lib.getExe cfg.packages.sddm-daemon} ${lib.escapeShellArg (toString sddmConfig)}";
          serviceConfig.KillMode = "mixed"; # - send SIGTERM only to the main process; required for a clean shutdown

          # - only attempt to start once (cryptsetup.target may have multiple start jobs queued)
          unitConfig.StartLimitBurst = 1;
          unitConfig.StartLimitIntervalSec = "infinity";

          # - load all KMS kernel modules before startup
          preStart = lib.mkIf (kmsModuleClosure != null) ''
            #Overlay the KMS modules over /lib/modules using an overlayfs
            # - make the mount rw to be able to bump the mtime later
            mkdir -p /tmp/kms-modules-upper /tmp/kms-modules-work
            mount -t overlay overlay \
              -o lowerdir=${kmsModuleClosure}/lib/modules:/lib/modules \
              -o upperdir=/tmp/kms-modules-upper \
              -o workdir=/tmp/kms-modules-work \
              /lib/modules

            #Reload the udev module index so that the new modules may be loaded
            # - kmod_validate_resources needs to return KMOD_RESOURCES_MUST_RECREATE, so bump the mtime of the new indices first
            find /lib/modules -type f -name 'modules.*' -exec touch -m {} \;
            udevadm control --reload

            #Trigger a udev reload to load any kernel modules that we need immediately
            udevadm trigger --type=all --action=add

            #Load modules we should load explicitly
            modprobe -a ${lib.escapeShellArgs cfg.kmsModules}
          '';

          # - if we fail, refresh the system's fbcon
          postStop = ''
            if [ "$SERVICE_RESULT" != "success" ]; then
              cat /sys/class/graphics/fbcon/rotate > /sys/class/graphics/fbcon/rotate
              systemctl try-restart systemd-ask-password-console.service
            fi
          '';

          environment = lib.mkMerge [
            # - configure the embedded QT backend
            (
              if !cfg.theme.qtSwRendering
              then {
                QT_QPA_PLATFORM = "eglfs";
                QT_QPA_EGLFS_INTEGRATION = "eglfs_kms"; # - can't use 'eglfs_kms_egldevice' since "we don't yet support EGL_DEVICE_DRM for the software device"
                GBM_BACKENDS_PATH = "${cfg.packages.mesa-minimal}/lib/gbm";
                __EGL_VENDOR_LIBRARY_FILENAMES = "${cfg.packages.mesa-minimal}/share/glvnd/egl_vendor.d/50_mesa.json";
              }
              else {
                QT_QPA_PLATFORM = "linuxfb";
              }
            )

            {
              # - configure the display outputs
              QT_QPA_KMS_CONFIG = toString kmsConfig;
              QT_FONT_DPI = toString cfg.displayDpi;

              # - configure the locale
              LC_ALL = cfg.locale;
              LOCALE_ARCHIVE = "${glibcLocales}/lib/locale/locale-archive";
            }

            # - configure the keyboard layout
            (let
              xkb = config.services.xserver.xkb;
            in {
              XKB_DEFAULT_MODEL = xkb.model;
              XKB_DEFAULT_LAYOUT = xkb.layout;
              XKB_DEFAULT_OPTIONS = xkb.options;
              XKB_DEFAULT_VARIANT = xkb.variant;
            })
          ];
        };

        # - send a signal to the daemon once /sysroot was mounted so it may pivot
        services.luks-sddm-capture-sysroot = {
          description = "SDDM Graphical LUKS Unlock - /sysroot pivot";

          after = ["luks-sddm.service" "initrd-nixos-activation.service"];
          before = ["initrd-switch-root.service"];
          requisite = ["luks-sddm.service"];
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

      kernelModules = ["loop"];
      availableKernelModules = ["evdev" "overlay"]; # - required for input / etc.

      #Configure the closure of things that are compressed / optionally sideloaded (handled in ./squashed-closure.nix)
      luks.sddmUnlock = {
        closureContents =
          [glibcLocales cfg.packages.sddm-daemon kmsConfig sddmConfig]
          ++ (lib.optional (kmsModuleClosure != null) kmsModuleClosure)
          ++ (lib.optional (!cfg.theme.qtSwRendering) cfg.packages.mesa-minimal);

        extraClosureRules = lib.optional (kmsModuleClosure != null) "!${kmsModuleClosure}/";
      };

      #Configure infinite retries for all devices we should unlock
      luks.devices = lib.genAttrs cfg.luksDevices (_: {crypttabExtraOpts = ["tries=0"];});
    };

    #Sync password changes (if enabled)
    security.pam.services = lib.mkIf cfg.syncPasswordChanges (lib.genAttrs ["login" "passwd" "chpasswd"] (srv: {
      rules.password.luks-password-sync = {
        control = "optional";
        modulePath = "${cfg.packages.luks-stage1-sddm}/lib/libluks_stage1_pam.so";
        args = lib.concatLists [
          ["cryptsetup=${lib.getExe pkgs.cryptsetup}"]
          (map (u: "user=${u}") cfg.users)
          (map (d: "luksDevice=${config.boot.initrd.luks.devices.${d}.device}") cfg.luksDevices)
        ];
        order = config.security.pam.services.${srv}.rules.password.unix.order - 10;
      };
    }));
  };
}
