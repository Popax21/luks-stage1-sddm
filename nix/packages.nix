{
  pkgs,
  crane,
}:
pkgs.lib.makeScope pkgs.newScope (self: {
  craneLib = crane self;
  cargoArtifacts = self.craneLib.buildDepsOnly {
    src = ./..;
    strictDeps = true;
  };

  qtbase-minimal = self.callPackage ./minimal-qtbase.nix {};
  sddm-minimal = self.callPackage ./minimal-sddm.nix {};

  luks-stage1-sddm = self.callPackage (
    {
      lib,
      craneLib,
      cargoArtifacts,
      sddm-minimal,
    }:
      craneLib.buildPackage {
        src = craneLib.cleanCargoSource ./..;
        strictDeps = true;
        inherit cargoArtifacts;

        EXE_SDDM_GREETER = lib.getExe' sddm-minimal "sddm-greeter-qt6";

        meta.mainProgram = "luks-stage1-sddm-daemon";
      }
  ) {};
})
