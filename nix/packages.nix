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

  qt6-minimal = self.callPackage ./minimal-qt6.nix {};
  kde-minimal = self.callPackage ./minimal-kde.nix {};
  sddm-minimal = self.callPackage ./minimal-sddm.nix {};

  luks-stage1-sddm = self.callPackage (
    {
      craneLib,
      cargoArtifacts,
      pam,
    }: let
      pkg = craneLib.buildPackage {
        src = craneLib.cleanCargoSource ./..;
        strictDeps = true;
        inherit cargoArtifacts;

        RUSTFLAGS = "-C link-args=-L${pam}/lib";
        TRANSIENT_SDDM_CONF = "/run/sddm-initrd-lucks-unlock.conf";
      };
    in
      pkg
  ) {};

  sddm-daemon = self.callPackage (
    {
      runCommandLocal,
      pam,
      luks-stage1-sddm,
    }:
      runCommandLocal "${luks-stage1-sddm.name}-daemon" {
        disallowedReferences = [pam];
        meta.mainProgram = "luks-stage1-sddm-daemon";
      } ''
        cp -R ${luks-stage1-sddm} $out
        chmod -R u+w $out
        rm -rf $out/lib
      ''
  ) {};
})
