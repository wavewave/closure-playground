{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  hsenv = haskellPackages.ghcWithPackages (p: with p; [
    containers
    distributed-closure
    network-simple
    monad-loops
    random
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
