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
      runCommandLocal,
      sddm-minimal,
      pam,
    }: let
      pkg = craneLib.buildPackage {
        src = craneLib.cleanCargoSource ./..;
        strictDeps = true;
        inherit cargoArtifacts;

        RUSTFLAGS = "-C link-args=-L${pam}/lib";

        EXE_SDDM_GREETER = lib.getExe' sddm-minimal "sddm-greeter-qt6";
        TRANSIENT_SDDM_CONF = "/run/sddm-initrd-lucks-unlock.conf";

        meta.mainProgram = "luks-stage1-sddm-daemon";

        passthru.nopam =
          runCommandLocal "${pkg.name}-nopam" {
            disallowedReferences = [pam];
          } ''
            cp -R ${pkg} $out
            chmod -R u+w $out
            rm -rf $out/lib
          '';
      };
    in
      pkg
  ) {};
})
