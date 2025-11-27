#Non-flake NixOS module entrypoint
{
  imports = [./module.nix];
  config.nixpkgs.overlays = [
    (final: prev: {
      luks-stage1-sddm = import ./.. {pkgs = final;};
    })
  ];
}
