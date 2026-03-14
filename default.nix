# For nix-env, nix-build, and nix-shell compatibility (non-flake usage).
# Flake users: use `nix run`, `nix profile install`, or `nix shell` instead.
{ pkgs ? import <nixpkgs> { } }:
pkgs.callPackage ./packaging/nix/package.nix { }
