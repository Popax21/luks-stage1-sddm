#Non-flake NixOS module entrypoint
{
  imports = [./module.nix];
  config.nixpkgs.overlays = [
    (final: prev: {
      inherit (import ./.. {pkgs = final;}) luks-stage1-sddm;
    })
  ];
}
