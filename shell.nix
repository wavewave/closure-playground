{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  newHaskellPackages = haskellPackages.override {
    overrides = self: super: {
    };
  };
  hsenv = newHaskellPackages.ghcWithPackages (p: with p; [
    cabal-install
    containers
    distributed-closure
    network-simple
    monad-loops
    random
    unliftio
    unordered-containers
  ]);
in

stdenv.mkDerivation {
  name = "closure-playground-test";

  buildInputs = [
    hsenv
  ];

  shellHook = ''
  '';
}
