#Non-flake NixOS module entrypoint
{
  imports = [./modules];
  config.nixpkgs.overlays = [
    (final: prev: {
      inherit (import ../../default.nix {pkgs = final;}) luks-stage1-sddm;
    })
  ];
}
