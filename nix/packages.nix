{
  pkgs,
  lib,
  craneLib,
}:
lib.makeScope pkgs.newScope (self: {
  inherit craneLib;

  cargoArtifacts = craneLib.buildDepsOnly {
    src = ./..;
    strictDeps = true;
  };

  luks-stage1-sddm = craneLib.buildPackage {
    src = ./..;
    strictDeps = true;
    inherit (self) cargoArtifacts;

    EXE_SDDM_GREETER = lib.getExe' pkgs.kdePackages.sddm "sddm-greeter-qt6";
    EXE_REPLY_PASSWORD = "${pkgs.systemd}/lib/systemd/systemd-reply-password";

    meta.mainProgram = "luks-stage1-sddm-daemon";
  };
})
