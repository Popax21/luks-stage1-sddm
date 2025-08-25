{
  pkgs ? import <nixpkgs> {},
  craneLib ?
    import (
      let
        craneInput = (builtins.fromJSON (builtins.readFile nix/flake.lock)).nodes.crane.locked;
      in
        fetchGit {
          url = "https://github.com/${craneInput.owner}/${craneInput.repo}";
          inherit (craneInput) rev;
        }
    ) {inherit pkgs;},
}:
pkgs.callPackage nix/packages.nix {inherit craneLib;}
