{
  pkgs ? import <nixpkgs> {},
  crane ?
    import (
      let
        craneInput = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.crane.locked;
      in
        fetchGit {
          url = "https://github.com/${craneInput.owner}/${craneInput.repo}";
          inherit (craneInput) rev;
        }
    ),
}:
import ./packages.nix {inherit pkgs crane;}
