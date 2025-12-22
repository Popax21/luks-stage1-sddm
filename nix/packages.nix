{
  pkgs,
  crane,
}:
pkgs.lib.makeScope pkgs.newScope (self: {
  stdenv = pkgs.withCFlags ["-Os"] pkgs.stdenv;

  libinput = pkgs.libinput.override {
    # - wacom support pulls in the entirety of Python ._.
    wacomSupport = false;
  };
  libxkbcommon = pkgs.libxkbcommon.overrideAttrs {
    # - don't depend on libx11 / libwayland
    outputs = ["out"];
    mesonFlags = [
      "-Denable-docs=false"
      "-Denable-x11=false"
      "-Denable-wayland=false"
      "-Dxkb-config-root=${pkgs.xkeyboard_config}/etc/X11/xkb"
    ];
  };
  libglvnd = pkgs.libglvnd.overrideAttrs (old: {
    # - disable GLX to remove X11 dependencies
    buildInputs = [];
    configureFlags = old.configureFlags ++ ["--disable-x11" "--disable-gles1" "--disable-gles2"];
  });

  craneLib = crane self;
  cargoArtifacts = self.craneLib.buildDepsOnly {
    src = ./..;
    strictDeps = true;
  };

  qt6-minimal = self.callPackage ./minimal-qt6.nix {};
  kde-minimal = self.callPackage ./minimal-kde.nix {};
  mesa-minimal = self.callPackage ./minimal-mesa.nix {};
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
