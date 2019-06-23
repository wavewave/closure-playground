{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  hsenv = haskellPackages.ghcWithPackages (p: with p; [
    distributed-closure
    network-simple
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
