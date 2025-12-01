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
      diskImage = lib.mkIf (!sideload) null;
      graphics = true;
      restrictNetwork = true;
      useBootLoader = lib.mkIf sideload true;
      useEFIBoot = lib.mkIf sideload true;
      qemu.options = ["-serial stdio"];
    };
    networking.dhcpcd.enable = false;

    boot.loader = lib.mkIf sideload {
      timeout = 0;
      systemd-boot.enable = true;
    };

    #Setup the testing user
    users.users.tester = {
      isNormalUser = true;
      password = "testing";
      extraGroups = ["wheel"];
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

          script = ''
            truncate -s 100M /tmp/test-drive
            echo -ne ${lib.escapeShellArg config.users.users.tester.password} \
              | cryptsetup luksFormat --batch-mode --force-password --type luks2 /tmp/test-drive -
            losetup /dev/loop7 /tmp/test-drive
          '';
          path = [pkgs.coreutils-full pkgs.util-linux pkgs.cryptsetup];
        };
        targets.cryptsetup.requiredBy = ["sysinit.target"];
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

    #Enable luks-stage1-sddm
    boot.initrd.luks.sddmUnlock = {
      enable = true;
      users = ["tester"];
      luksDevices = ["test-drive"];
      # sideloadClosure = true; # - expensive to test!
    };

    boot.initrd.systemd.services.luks-sddm.environment.RUST_BACKTRACE = "1";
    boot.initrd.availableKernelModules = ["bochs"]; # - required to get DRI/DRM working in the initrd

    #Drop a shell in the stage 1 initrd
    services.journald.console = "/dev/ttyS0";
    boot.initrd.systemd.contents."/etc/systemd/journald.conf".source = config.environment.etc."systemd/journald.conf".source;

    boot.kernelParams = ["rd.systemd.unit=rescue.target"];
    boot.initrd.systemd = {
      emergencyAccess = true;
      extraBin = {
        grep = lib.getExe pkgs.gnugrep;
        dmesg = lib.getExe' pkgs.util-linux "dmesg";
      };
    };
  };
}
