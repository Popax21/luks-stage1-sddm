{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;

  defaultConfig = {
    General.DisplayServer = "wayland";
    Theme.Current = cfg.theme;
    LUKSUnlock.Devices = map (name: config.boot.initrd.luks.devices.${name}.device) cfg.luksDevices;
  };

  iniFmt = pkgs.formats.ini {listsAsDuplicateKeys = true;};
  sddmConfig = iniFmt.generate "initrd-sddm.conf" (lib.recursiveUpdate defaultConfig cfg.settings);

  squashedClosurePath = "/luks-sddm-closure.sqsh";
  squashedClosure = pkgs.runCommand "initrd-sddm-closure.sqsh" {
    __structuredAttrs = true;
    exportReferencesGraph.closure = [cfg.package sddmConfig];
    unsafeDiscardReferences.out = true;

    nativeBuildInputs = with pkgs; [python3 squashfsTools];

    excludePatterns = let
      matchPkg = name: "${builtins.storeDir}/[a-z0-9]+-${name}-[^/]+";
      matchAllPkgs = "${builtins.storeDir}/[^/]+";
    in [
      # - only include /lib / /share
      "${matchAllPkgs}/"
      "!${matchAllPkgs}/lib/[^/]+\\.so(.[^/]+)?"
      "!${matchAllPkgs}/lib/qt-6/"
      "!${matchAllPkgs}/share/"
      "${matchAllPkgs}/share/doc/"
      "${matchAllPkgs}/share/man/"
      "${matchAllPkgs}/share/i18n/"
      "${matchAllPkgs}/share/locale/"
      "${matchAllPkgs}/share/pkgconfig/"

      # - exclude libasan / libtsan / ...
      "${matchPkg "gcc"}/lib/"
      "!${matchPkg "gcc"}/lib/libgcc_s.so(.[^/]+)?"
      "!${matchPkg "gcc"}/lib/libstdc\\+\\+.so(.[^/]+)?"
      "!${matchPkg "gcc"}/lib/libgomp.so(.[^/]+)?"

      # - bunch of package-specific fixups
      "${matchPkg "hwdata"}/" # - we don't need hwdata
      "${matchPkg "glib"}/lib/(?!libglib-2.0.so)[^/]+" # - we only need libglib-2.0.so
      "${matchPkg "systemd-minimal-libs"}/lib/(?!libudev.so)[^/]+" # - we only need udev
      "!${matchPkg "xkeyboard-config"}/etc" # - is a symlink
      "!${matchPkg "glibc"}/lib/locale/C.utf8/" # - required for UTF-8 locale support

      # - include the binaries we actually use
      "!${lib.getExe' cfg.package "luks-stage1-sddm-daemon"}"
      "!${matchPkg "sddm-minimal"}/bin/sddm-greeter-qt6"
    ];
  } "python3 ${./build-closure.py}";
in {
  options.boot.initrd.luks.sddmUnlock = {
    enable = lib.mkEnableOption "LUKS unlock using SDDM in initrd";
    package = lib.mkPackageOption pkgs.luks-stage1-sddm "luks-stage1-sddm" {pkgsText = "pkgs.luks-stage1-sddm";};

    pinPkgs = lib.mkOption {
      type = lib.types.nullOr (lib.types.functionTo lib.types.attrs);
      default = null;
      description = ''
        Pin the SDDM initrd packages to the specific nixpkgs instance.
        Can be used to prevent excessive rebuilds of the squashed SDDM closure.
        When using the flake entrypoint, this will default to the locked nixpkgs input.
      '';
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

    theme = lib.mkOption {
      type = lib.types.str;
      description = "Greeter theme to use.";
      default = config.services.displayManager.sddm.theme;
      defaultText = lib.literalExpression "config.services.displayManager.sddm.theme";
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
        enable = true;

        #Copy the squashed closure into the initrd
        storePaths = [
          {
            source = squashedClosure;
            target = squashedClosurePath;
          }
        ];

        #Setup the SDDM service
        services.luks-sddm = {
          description = "SDDM Graphical LUKS Unlock";

          after = ["systemd-sysctl.service" "systemd-udevd.service" "localfs.target"];
          before = ["cryptsetup-pre.target" "systemd-ask-password-console.service"];
          wantedBy = ["cryptsetup.target"];
          unitConfig.DefaultDependencies = false;

          serviceConfig.Type = "notify";
          serviceConfig.ExecStart = "${lib.getExe' cfg.package "luks-stage1-sddm-daemon"} ${lib.escapeShellArg (toString sddmConfig)}";

          # - mount the squashed closure before startup
          preStart = ''
            mkdir -p /tmp/luks-sddm-closure
            mount -t squashfs -o loop ${lib.escapeShellArg squashedClosurePath} /tmp/luks-sddm-closure
            mount -t overlay overlay -o lowerdir=${builtins.storeDir}:/tmp/luks-sddm-closure${builtins.storeDir} ${builtins.storeDir}
          '';

          # - if we fail, refresh the system's fbcon
          postStop = ''
            if [ "$SERVICE_RESULT" != "success" ]; then
              cat /sys/class/graphics/fbcon/rotate > /sys/class/graphics/fbcon/rotate
              systemctl try-restart systemd-ask-password-console.service
            fi
          '';

          # - configure the embedded QT backend
          environment = {
            QT_QPA_PLATFORM = "linuxfb";
            QT_QPA_FB_DRM = "1";
          };
        };

        #Setup users we should be able to log in as
        users = lib.listToAttrs (lib.imap0
          (idx: name: {
            inherit name;
            value.uid = 10000 + idx; # - exact value doesn't matter
            value.group = "nogroup";
          })
          cfg.users);
      };

      #We need to enable support for some things we need to have early in initrd
      supportedFilesystems.squashfs = true;
      availableKernelModules = ["evdev"]; # - required for input / etc.

      #Configure infinite retries for all devices we should unlock
      luks.devices = lib.genAttrs cfg.luksDevices (_: {crypttabExtraOpts = ["tries=0"];});
    };

    nixpkgs.overlays = lib.optional (cfg.pinPkgs != null) (final: prev: {
      luks-stage1-sddm = prev.luks-stage1-sddm.overrideScope (cfg.pinPkgs final.stdenv.targetPlatform.system);
    });
  };
}
