{
  self,
  nixpkgs,
  system,
}: let
  config = nixpkgs.lib.nixosSystem {
    modules = [
      {nixpkgs.system = system;}
      ./configuration.nix
    ];
    specialArgs.flake = self;
  };
  vm = config.config.system.build.vm;
in {
  type = "app";
  program = "${vm}/bin/run-nixos-vm";
  meta.description = "Development VM";

  inherit config;
  roots = nixpkgs.legacyPackages.${system}.runCommandLocal "luks-stage1-sddm-dev-vm-roots" {
    propagatedBuildInputs = config.config.boot.initrd.luks.sddmUnlock.closureBuildDeps;
  } "touch $out";
}
