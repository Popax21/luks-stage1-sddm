{
  config,
  options,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;

  squashedClosurePath = "/luks-sddm-closure.sqsh";
  squashedClosure = pkgs.runCommand "initrd-sddm-closure.sqsh" {
    __structuredAttrs = true;
    exportReferencesGraph.closure = cfg.closureContents;
    unsafeDiscardReferences.out = true;

    outputs = ["out" "hash"];
    nativeBuildInputs = with pkgs; [python3 squashfsTools];

    excludePatterns = let
      matchPkg = name: "${builtins.storeDir}/[a-z0-9]+-${name}(?:-[^/]+)?";
      matchAllPkgs = "${builtins.storeDir}/[^/]+";
    in
      [
        # - only include /lib / /share
        "${matchAllPkgs}/"
        "!${matchAllPkgs}/lib/[^/]+\\.so(.[^/]+)?"
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

        # - only include as few Qt plugins as we can get away with (QML is fine tho)
        "!${matchPkg "qtbase"}/lib/qt-6/plugins/"
        "!${matchPkg "qtsvg"}/lib/qt-6/plugins/"
        "!${matchAllPkgs}/lib/qt-6/qml/"

        # - exclude all SDDM themes except the one we use
        "${matchAllPkgs}/share/sddm/themes/"
        (lib.optionalString (cfg.theme.name != "") "!${matchPkg "initrd-sddm-theme-env"}/share/sddm/themes/${cfg.theme.name}/")

        # - bunch of package-specific fixups
        "!${matchPkg "glibc"}/lib/locale/" # - locale archive data
        "${matchPkg "hwdata"}/" # - we don't need hwdata
        "${matchPkg "glib"}/lib/(?!libglib-2.0.so)[^/]+" # - we only need libglib-2.0.so
        "${matchPkg "systemd-minimal-libs"}/lib/(?!libudev.so)[^/]+" # - we only need udev
        "!${matchPkg "xkeyboard-config"}/etc" # - is a symlink
        "!${matchPkg "mesa"}/lib/gbm/" # - Mesa stuff

        # - include the binaries we actually use
        "!${matchPkg "luks-stage1-sddm"}/bin/luks-stage1-sddm-daemon"
        "!${matchPkg "sddm-minimal"}/bin/sddm-greeter-qt6"
      ]
      ++ cfg.theme.extraClosureRules;
  } "python3 ${./build-closure.py}";

  efiDir = config.boot.loader.efi.efiSysMountPoint;
in {
  options.boot.initrd.luks.sddmUnlock = {
    pinPkgs = lib.mkOption {
      type = lib.types.nullOr (lib.types.functionTo lib.types.attrs);
      default = null;
      description = ''
        Pin the SDDM initrd packages to the specific nixpkgs instance.
        Can be used to prevent excessive rebuilds of the squashed SDDM closure.
        When using the flake entrypoint, this will default to the locked nixpkgs input.
      '';
    };

    rootBuildDeps = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep the build dependencies of the SDDM initrd closure alive.";
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

    closureContents = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      internal = true;
    };
    closureBuildDeps = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd.systemd = {
      #Copy the squashed closure into the initrd
      # - unless we're sideloading it, then we just need to copy its hash (and the tools to validate it)
      storePaths = lib.mkMerge [
        (lib.mkIf (!cfg.sideloadClosure) [
          {
            source = squashedClosure;
            target = squashedClosurePath;
          }
        ])

        (lib.mkIf cfg.sideloadClosure [
          squashedClosure.hash
          (lib.getExe' pkgs.coreutils "sha256sum")
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

      #Mount the squashed closure before startup
      services.luks-sddm = {
        preStart = ''
          mkdir -p /tmp/luks-sddm-closure
          mount -t squashfs -o loop ${lib.escapeShellArg squashedClosurePath} /tmp/luks-sddm-closure
          mount -t overlay overlay -o lowerdir=${builtins.storeDir}:/tmp/luks-sddm-closure${builtins.storeDir} ${builtins.storeDir}
        '';
        unitConfig.ConditionPathExists = squashedClosurePath;
      };
    };

    #Enable support for the EFI FS in the initrd if we need to mount it for sideloading
    boot.initrd.supportedFilesystems = lib.mkIf cfg.sideloadClosure {
      ${config.fileSystems.${efiDir}.fsType} = true;
    };

    #Copy the squashed closure directly to the EFI partition (if enabled)
    system.build.installBootLoader = lib.mkIf cfg.sideloadClosure (
      let
        buildOpt = options.system.build;
        buildDefs = builtins.filter (d: d.file != (toString ./squashed-closure.nix)) buildOpt.definitionsWithLocations;
        buildVal = buildOpt.type.merge buildOpt.loc buildDefs;
      in
        lib.mkForce (pkgs.writeShellScript "install-bootloader-hooked" ''
          ${buildVal.installBootLoader} "$@"
          echo "Installing squashed SDDM initrd closure for graphical LUKS unlock"
          ${lib.getExe' pkgs.coreutils "cp"} ${squashedClosure} "${efiDir}/${squashedClosurePath}"
        '')
    );

    #Pin the initrd closure packages (if enabled)
    nixpkgs.overlays = lib.optional (cfg.pinPkgs != null) (final: prev: {
      luks-stage1-sddm = lib.makeScope (cfg.pinPkgs final.stdenv.targetPlatform.system).newScope prev.luks-stage1-sddm.packages;
    });

    #Keep the closure build dependencies alive (if enabled)
    system.extraDependencies = cfg.closureBuildDeps;
    boot.initrd.luks.sddmUnlock.closureBuildDeps = cfg.closureContents;
  };
}
