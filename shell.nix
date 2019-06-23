{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  hsenv = haskellPackages.ghcWithPackages (p: with p; [
    distributed-closure
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
