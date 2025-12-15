{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.luks.sddmUnlock;

  sddmEnable = config.services.displayManager.sddm.enable;
  sddmEnable' = lib.warnIfNot sddmEnable "Graphical LUKS unlocking using SDDM in initrd is enabled, but SDDM itself is disabled" sddmEnable;
in {
  config = lib.mkIf (cfg.enable && sddmEnable') {
    #Create a symlink in /etc/sddm.conf.d which points to our ephemerally generated SDDM config file
    environment.etc."sddm.conf.d/initrd-luks-unlock.conf".source = toString (
      pkgs.runCommandLocal "sddm-initrd-luks-unlock-link" {} "ln -s ${cfg.package.TRANSIENT_SDDM_CONF} $out"
    );

    #Leave the stage1 greeter running until the proper SDDM service has started
    boot.initrd.systemd.services.luks-sddm = {
      conflicts = ["shutdown.target"];
      unitConfig.IgnoreOnIsolate = true;
      unitConfig.SurviveFinalKillSignal = true;
    };

    systemd.services = {
      # - reclaim the cgroup, otherwise we get sent a SIGTERM from the stage2 systemd manager
      luks-sddm = {
        wantedBy = ["graphical.target"]; # - if we're not booting into graphical.target, we still want to get sent a SIGTERM
        unitConfig.Type = "forking";
        unitConfig.DefaultDependencies = false;
        script = "exit";
      };

      # - once display-manager.service starts, shut down the stage1 SDDM instance
      #   (we can't use `conflicts = [...];` since that would queue the stop job right away)
      display-manager.preStart = "systemctl stop luks-sddm.service";
    };
  };
}
