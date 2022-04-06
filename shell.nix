let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};
  unstable = import <nix-unstable> {};

ispc = pkgs.ispc.overrideAttrs (oldAttrs: rec {
    version = "1.17.0";
    src = builtins.fetchTarball {
      url = "https://github.com/ispc/ispc/archive/refs/tags/v${version}.tar.gz";
      sha256 = "1klk1mhxjvyhzf1kqznimdb2f96czp76k8riv8yda87gfrk7cmfn";
    };
    patches = [];
  });
in
pkgs.stdenv.mkDerivation {
  name = "futhark";
  buildInputs = [
    pkgs.cabal-install
    pkgs.cacert
    pkgs.curl
    pkgs.file
    pkgs.git
    pkgs.git-annex
    #pkgs.ghc
    unstable.haskell.compiler.ghc902
    unstable.haskell.packages.ghc902.haskell-language-server
    #pkgs.ispc
    pkgs.stack
    pkgs.haskellPackages.weeder
    pkgs.hlint
    pkgs.pkgconfig
    pkgs.zlib
    pkgs.zlib.out
    pkgs.cabal2nix
    pkgs.ghcid
    #pkgs.haskell.packages.ghc921.ormolu_0_4_0_0
    pkgs.niv
    pkgs.python3Packages.numpy
    pkgs.python3Packages.pyopencl
    pkgs.python3Packages.jsonschema
    pkgs.python3Packages.sphinx
    pkgs.python3Packages.sphinxcontrib-bibtex
    pkgs.imagemagick # needed for literate tests
    ispc
  ]
  ++ pkgs.lib.optionals (pkgs.stdenv.isLinux)
    [ pkgs.opencl-headers
      pkgs.ocl-icd ]
  ;
  shellHooks=''
    export PATH=$PATH:~/.local/bin
    alias skkrt='stack build --fast && stack install'
  '';
}
