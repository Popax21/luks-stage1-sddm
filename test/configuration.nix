{
  lib,
  pkgs,
  config,
  flake,
  modulesPath,
  efiSupport,
  ...
}: {
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    flake.nixosModules.default
  ];
  config = {
    system.stateVersion = "24.05";

    #Configure the VM
    nix.enable = false;
    virtualisation = {
      memorySize = 4096;

      graphics = true;
      resolution.x = 1920;
      resolution.y = 1080;

      diskImage = lib.mkIf (!efiSupport) null;
      restrictNetwork = true;
      qemu.options = ["-vga virtio" "-serial stdio"];

      useBootLoader = lib.mkIf efiSupport true;
      useEFIBoot = lib.mkIf efiSupport true;
    };
    networking.dhcpcd.enable = false;
    services.journald.console = "/dev/ttyS0";

    boot.loader = lib.mkIf efiSupport {
      timeout = 0;
      systemd-boot.enable = true;
    };

    #Setup a swap file for hibernation support
    # - has to be stronger than mkVMOverride (priority 10)
    swapDevices = lib.mkOverride 5 (
      lib.optionals efiSupport [
        {
          device = "/swapfile";
          size = config.virtualisation.memorySize;
        }
      ]
    );

    # - ensure that root partition is big enough to hold the swapfile
    virtualisation.diskSize = lib.mkIf efiSupport (8192 + config.virtualisation.memorySize);
    virtualisation.fileSystems."/".autoResize = lib.mkIf efiSupport true;
    boot.growPartition = lib.mkIf efiSupport true;
    systemd.services.mkswap-swapfile.after = lib.mkIf efiSupport ["growpart.service" "systemd-growfs-root.service"];

    #Setup localization to ensure it works in the initrd
    i18n.defaultLocale = "de_AT.UTF-8";
    time.timeZone = "Europe/Vienna";
    services.xserver.xkb.layout = "at";

    #Setup testing users
    users.users = {
      tester = {
        isNormalUser = true;
        password = "xyz";
        extraGroups = ["wheel"];
      };
      tester2 = {
        isNormalUser = true;
        password = "xyz2";
      };
    };
    users.users.root.password = "testing";

    #Setup a testing LUKS-encrypted drive
    boot.initrd = {
      systemd = {
        enable = true;
        storePaths = [pkgs.coreutils-full pkgs.util-linux pkgs.cryptsetup];

        services.test-drive-setup = {
          before = ["cryptsetup-pre.target"];
          requiredBy = ["sysinit.target"];

          unitConfig.DefaultDependencies = false;
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;

          script = let
            slotKeyFor = user: "${user}#${config.users.users.${user}.password}";
          in ''
            truncate -s 100M /tmp/test-drive

            printf '%s' ${lib.escapeShellArg (slotKeyFor "tester")} \
              | cryptsetup luksFormat --batch-mode --force-password --type luks2 /tmp/test-drive -

            printf '%s\n' ${lib.escapeShellArgs (map slotKeyFor ["tester" "tester2" "tester2"])} \
              | cryptsetup luksAddKey --batch-mode --force-password /tmp/test-drive

            losetup /dev/loop7 /tmp/test-drive
          '';
          path = [pkgs.coreutils-full pkgs.util-linux pkgs.cryptsetup];
        };
        targets.cryptsetup = {
          before = ["sysroot.mount"];
          requiredBy = ["sysroot.mount"];
        };

        # - "fake" the swap file also being LUKS-encrypted
        services.systemd-hibernate-resume = lib.mkIf efiSupport {
          overrideStrategy = "asDropin";
          after = ["dev-mapper-test\\x2ddrive.device"];
          requires = ["dev-mapper-test\\x2ddrive.device"];
        };
      };
      kernelModules = ["loop"];

      # - has to be stronger than mkVMOverride (priority 10)
      luks.devices = lib.mkOverride 5 {
        test-drive = {
          device = "/dev/loop7";
          crypttabExtraOpts = ["tries=0"];
        };
      };
    };

    #Setup debugging in the initrd
    boot.initrd.systemd = {
      emergencyAccess = true;
      extraBin = {
        grep = lib.getExe pkgs.gnugrep;
        dmesg = lib.getExe' pkgs.util-linux "dmesg";
      };
      contents."/etc/systemd/journald.conf".source = config.environment.etc."systemd/journald.conf".source;
    };

    # boot.kernelParams = ["rd.systemd.unit=rescue.target"]; # - use this to drop a shell in the stage 1 initrd

    #Enable a minimal stub DM + DE
    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      sessionPackages = [
        (pkgs.writeTextFile {
          name = "fake-de-session";
          destination = "/share/wayland-sessions/fake-de.desktop";
          passthru.providedSessions = ["fake-de"];
          text = ''
            [Desktop Entry]
            DesktopNames=FakeDE
            Name=Fake Desktop Environment
            Exec=${lib.getExe pkgs.cage} -- ${lib.getExe pkgs.foot}
            TryExec=/bin/sh
          '';
        })
        (pkgs.writeTextFile {
          name = "fake-de2-session";
          destination = "/share/wayland-sessions/fake-de2.desktop";
          passthru.providedSessions = ["fake-de2"];
          text = ''
            [Desktop Entry]
            DesktopNames=FakeDE2
            Name=Fake Desktop Environment 2
            Exec=sleep 5
            TryExec=/bin/sh
          '';
        })
      ];
    };

    #Enable luks-stage1-sddm
    boot.initrd.luks.sddmUnlock = lib.mkMerge [
      {
        enable = true;
        users = ["tester" "tester2"];
        luksDevices = ["test-drive"];

        theme.name = "breeze";
        # displayDpi = 144; # - 150%
      }

      (lib.mkIf efiSupport {
        # - non-KMS / EFI GOP
        # displayOutputs."GOP".mode = "1920x1080";
        # sideloadClosure = true; # - expensive to test!
      })

      (lib.mkIf (!efiSupport) {
        # - KMS
        kmsModules = ["virtio-gpu"];
        displayOutputs."Virtual1".mode = "1920x1080";
        sideloadClosure = false;
      })
    ];

    boot.initrd.systemd.services.luks-sddm.environment.RUST_BACKTRACE = "1";
  };
}
