{ pkgs ? import <nixpkgs> { } }:
with pkgs;
let
  hpkgs = haskellPackages;
  ghcWithDeps = hpkgs.ghcWithPackages (p: with p; [
    amazonka
    amazonka-core
    amazonka-s3
    async
    bytestring
    conduit
    conduit-extra
    containers
    directory
    effectful-core
    effectful-th
    exceptions
    extra
    filepath
    generic-lens
    lens
    monad-logger
    network
    optparse-applicative
    resourcet
    retry
    sqlite-simple
    stm
    text
    time
    unix
    unliftio
    unliftio-core
    # test deps
    HUnit
    QuickCheck
    tasty
    tasty-discover
    tasty-hunit
    tasty-quickcheck
  ]);
in
mkShell {
  buildInputs = [
    ghcWithDeps
    sqlite-interactive
    stylish-haskell
    hlint
    ghcid
    hpkgs.haskell-language-server
    hpkgs.tasty-discover
    cabal-install
    hpack
    zlib
  ];

  shellHook = ''
    # ...
  '';
}
