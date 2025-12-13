{
  config,
  options,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;
  dmCfg = config.services.displayManager;

  defaultConfig =
    {
      Theme.Current = cfg.theme;
      LUKSUnlock.Devices = map (name: config.boot.initrd.luks.devices.${name}.device) cfg.luksDevices;
    }
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

  squashedClosurePath = "/luks-sddm-closure.sqsh";
  squashedClosure = pkgs.runCommand "initrd-sddm-closure.sqsh" {
    __structuredAttrs = true;
    exportReferencesGraph.closure = [cfg.package sddmConfig];
    unsafeDiscardReferences.out = true;

    outputs = ["out" "hash"];
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

  efiDir = config.boot.loader.efi.efiSysMountPoint;
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

    sideloadClosure = lib.mkOption {
      type = lib.types.bool;
      default = config.boot.loader.systemd-boot.enable || (config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport);
      defaultText = lib.literalExpression ''config.boot.loader.systemd-boot.enable || (config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport)'';
      description = ''
        Don't store the squashed SDDM closure in the initrd itself, and instead store it directly on the EFI partition.
        This can be used to reduce the size of the generated initrd.
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

        storePaths = lib.mkMerge [
          #Copy the squashed closure into the initrd
          (lib.mkIf (!cfg.sideloadClosure) [
            {
              source = squashedClosure;
              target = squashedClosurePath;
            }
          ])

          # - unless we're sideloading it, then we just need to copy its hash (and the tools to validate it)
          (lib.mkIf cfg.sideloadClosure [
            squashedClosure.hash
            (lib.getExe' pkgs.coreutils "sha256sum")
          ])

          #Set the timezone if configured
          (lib.mkIf (config.time.timeZone != null) [
            {
              source = "${pkgs.tzdata}/share/zoneinfo/${config.time.timeZone}";
              target = "/etc/localtime";
            }
          ])
        ];

        #If we're sideloading copy the closure from the EFI partition
        services.luks-sddm-acquire-closure = lib.mkIf cfg.sideloadClosure {
          description = "Acquire SDDM Closure for Graphical LUKS Unlock";

          before = ["luks-sddm.service"];
          requiredBy = ["luks-sddm.service"];
          unitConfig.DefaultDependencies = false;

          unitConfig.RequiresMountsFor = "/efi";
          unitConfig.ConditionPathExists = "/efi/${squashedClosurePath}";

          serviceConfig.Type = "oneshot";
          script = let
            escp = lib.escapeShellArg squashedClosurePath;
          in ''
            cp /efi/${escp} ${escp}-unver
            if sha256sum -c --status --strict <(echo $(cat ${squashedClosure.hash}) ${escp}-unver); then
              echo squashed LUKS closure hash OK
              mv ${escp}-unver ${escp}
            else
              echo squashed LUKS closure hash mismatch! >&2
              exit 1
            fi
          '';
        };
        mounts = lib.mkIf cfg.sideloadClosure [
          (let
            efiFs = config.fileSystems.${efiDir};
          in
            assert efiFs.enable;
            assert efiFs.depends == [];
            assert !efiFs.encrypted.enable; {
              what = efiFs.device;
              where = "/efi";
              type = efiFs.fsType;
              options = lib.concatStringsSep "," (["ro"] ++ (lib.remove "rw" efiFs.options));
            })
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
          unitConfig.ConditionPathExists = squashedClosurePath;

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
      supportedFilesystems = lib.mkMerge [
        {
          squashfs = true;
          overlay = true;
        }
        (lib.mkIf cfg.sideloadClosure {
          ${config.fileSystems.${efiDir}.fsType} = true;
        })
      ];

      availableKernelModules = ["evdev" "overlay"]; # - required for input / etc.

      #Configure infinite retries for all devices we should unlock
      luks.devices = lib.genAttrs cfg.luksDevices (_: {crypttabExtraOpts = ["tries=0"];});
    };

    #Pin the initrd closure packages (if enabled)
    nixpkgs.overlays = lib.optional (cfg.pinPkgs != null) (final: prev: {
      luks-stage1-sddm = prev.luks-stage1-sddm.overrideScope (cfg.pinPkgs final.stdenv.targetPlatform.system);
    });

    #Copy the squashed closure directly to the EFI partition (if enabled)
    system.build.installBootLoader = lib.mkIf cfg.sideloadClosure (
      let
        buildOpt = options.system.build;
        buildDefs = builtins.filter (d: d.file != (toString ./module.nix)) buildOpt.definitionsWithLocations;
        buildVal = buildOpt.type.merge buildOpt.loc buildDefs;
      in
        lib.mkForce (pkgs.writeShellScript "install-bootloader-hooked" ''
          ${buildVal.installBootLoader} "$@"
          echo "Installing squashed SDDM initrd closure for graphical LUKS unlock"
          cp ${squashedClosure} "${efiDir}/${squashedClosurePath}"
        '')
    );
  };
}
