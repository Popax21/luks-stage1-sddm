{
  lib,
  pkgs,
  config,
  flake,
  modulesPath,
  ...
}: {
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    flake.nixosModules.default
  ];
  config = let
    sideload = config.boot.initrd.luks.sddmUnlock.sideloadClosure;
  in {
    system.stateVersion = "24.05";

    #Configure the VM
    nix.enable = false;
    virtualisation = {
      memorySize = 4096;

      graphics = true;
      resolution.x = 1920;
      resolution.y = 1080;

      diskImage = lib.mkIf (!sideload) null;
      restrictNetwork = true;
      qemu.options = ["-vga virtio" "-serial stdio"];

      useBootLoader = lib.mkIf sideload true;
      useEFIBoot = lib.mkIf sideload true;
    };
    networking.dhcpcd.enable = false;
    services.journald.console = "/dev/ttyS0";

    boot.loader = lib.mkIf sideload {
      timeout = 0;
      systemd-boot.enable = true;
    };

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
            users = config.users.users;
          in ''
            truncate -s 100M /tmp/test-drive

            printf '%s' ${lib.escapeShellArg users.tester.password} \
              | cryptsetup luksFormat --batch-mode --force-password --type luks2 /tmp/test-drive -

            printf '%s\n' ${lib.escapeShellArgs [users.tester.password users.tester2.password users.tester2.password]} \
              | cryptsetup luksAddKey --batch-mode --force-password /tmp/test-drive

            losetup /dev/loop7 /tmp/test-drive
          '';
          path = [pkgs.coreutils-full pkgs.util-linux pkgs.cryptsetup];
        };
        targets.cryptsetup = {
          before = ["sysroot.mount"];
          requiredBy = ["sysroot.mount"];
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
            Exec=sleep 5
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
    boot.initrd.luks.sddmUnlock = {
      enable = true;
      users = ["tester" "tester2"];
      luksDevices = ["test-drive"];
      sideloadClosure = false; # true; # - expensive to test!

      displayOutputs."Virtual1".mode = "1920x1080";
      displayDpi = 144; # - 150%
      theme.name = "breeze";
    };

    boot.initrd.systemd.services.luks-sddm.environment.RUST_BACKTRACE = "1";
    boot.initrd.availableKernelModules = ["bochs"]; # - required to get DRI/DRM working in the initrd
  };
}
