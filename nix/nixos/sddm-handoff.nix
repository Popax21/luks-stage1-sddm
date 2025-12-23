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
    warnings = lib.mkIf (config.security.pam.services.login.fprintAuth) [
      ''
        Fingerprint login is enabled, which will conflict with luks-stage1-sddm.
        Consider switching to just fingerprint unlocking by setting `security.pam.services.login.fprintAuth = false;`.
      ''
    ];

    #Create a symlink in /etc/sddm.conf.d which points to our ephemerally generated SDDM config file
    environment.etc."sddm.conf.d/initrd-luks-unlock.conf".source = toString (
      pkgs.runCommandLocal "sddm-initrd-luks-unlock-link" {} "ln -s ${cfg.packages.luks-stage1-sddm.TRANSIENT_SDDM_CONF} $out"
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
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "forking";
        script = "exit";
      };

      # - once display-manager.service starts, shut down the stage1 SDDM instance
      #   (we can't use `conflicts = [...];` since that would queue the stop job right away)
      display-manager.preStart = "systemctl stop luks-sddm.service";
    };

    #Configure a PAM module to properly perform the handoff
    security.pam.services.sddm-autologin.text = lib.mkBefore ''
      auth [success=ignore user_unknown=2 default=bad] ${cfg.packages.luks-stage1-sddm}/lib/libluks_stage1_pam.so
      auth include sddm
      auth [default=done] pam_permit.so
    '';
  };
}
