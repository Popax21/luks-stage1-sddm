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
  passthru = rec {
    inherit config;
    sddmClosure = config.config.boot.initrd.luks.sddmUnlock.closureContents;
    sddmConf = nixpkgs.lib.findFirst (p: p.name == "initrd-sddm.conf") null sddmClosure;
  };
}
