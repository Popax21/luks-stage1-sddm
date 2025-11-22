{
  description = "Unlock LUKS drives using SDDM from NixOS stage1";

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
    (flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      craneLib = crane.mkLib pkgs;
      flakePkgs = pkgs.callPackage nix/packages.nix {inherit craneLib;};
    in rec {
      packages = rec {
        inherit (flakePkgs) luks-stage1-sddm;
        default = luks-stage1-sddm;
      };

      checks =
        packages
        // {
          rustfmt = craneLib.cargoFmt {
            src = ./.;
          };
          clippy = craneLib.cargoClippy {
            src = ./.;

            inherit (flakePkgs) cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets --all-features -- --deny warnings";
          };
        };

      devShells.default = craneLib.devShell {
        checks = checks;
        packages = with pkgs; [
          clippy
          rust-analyzer
        ];
        propagatedBuildInputs = [flakePkgs.cargoArtifacts]; # - keep our cargo artifacts alive as part of the direnv GC root
      };

      apps.devVM = import test/dev_vm.nix {inherit self nixpkgs system;};
    }))
    // rec {
      overlays.default = final: prev: {
        inherit (final.callPackages nix/packages.nix {craneLib = crane.mkLib final;}) luks-stage1-sddm;
      };

      nixosModules.default = {
        imports = [nix/nixos/module.nix];
        config.nixpkgs.overlays = [overlays.default];
      };
    };
}
