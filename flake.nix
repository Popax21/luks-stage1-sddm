{
  description = "Unlock LUKS drives using SDDM from NixOS stage1 / initrd";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    crane,
    ...
  }:
    (flake-utils.lib.eachSystem (builtins.filter (nixpkgs.lib.hasInfix "linux") flake-utils.lib.defaultSystems) (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      flakePkgs = import nix/packages.nix {
        inherit pkgs;
        crane = crane.mkLib;
      };
    in rec {
      packages = flake-utils.lib.flattenTree {
        inherit (flakePkgs) mesa-minimal sddm-minimal luks-stage1-sddm sddm-daemon;
        qt6-minimal = lib.recurseIntoAttrs (lib.filterAttrs (_: lib.isDerivation) (removeAttrs flakePkgs.qt6-minimal ["full"]));
        kde-minimal = lib.recurseIntoAttrs (lib.filterAttrs (_: lib.isDerivation) (removeAttrs flakePkgs.kde-minimal (lib.attrNames flakePkgs.qt6-minimal)));
      };

      checks = {
        inherit (flakePkgs) luks-stage1-sddm sddm-daemon;

        rustfmt = flakePkgs.craneLib.cargoFmt {
          src = ./.;
        };
        clippy = flakePkgs.craneLib.cargoClippy {
          src = ./.;
          inherit (flakePkgs) cargoArtifacts;
          cargoClippyExtraArgs = "--all-targets --all-features -- --deny warnings";
        };
      };

      devShells.default = flakePkgs.craneLib.devShell {
        checks = checks;
        packages = with pkgs; [
          clippy
          rust-analyzer
        ];

        # - keep our cargo artifacts alive as part of the direnv GC root
        propagatedBuildInputs = [flakePkgs.cargoArtifacts];
      };

      apps.devVM = import test/dev_vm.nix {inherit self nixpkgs system;};
    }))
    // rec {
      overlays.default = final: prev: {
        luks-stage1-sddm = import nix/packages.nix {
          pkgs = final;
          crane = crane.mkLib;
        };
      };

      nixosModules.default = {
        imports = [
          nix/nixos/module.nix
          {
            boot.initrd.luks.sddmUnlock.pinPkgs = nixpkgs.lib.mkDefault (system: nixpkgs.legacyPackages.${system});
          }
        ];
        config.nixpkgs.overlays = [overlays.default];
      };
    };
}
