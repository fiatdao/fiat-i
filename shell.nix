let
  pkgs = import (builtins.fetchGit rec {
    name = "dapptools-${rev}";
    url = https://github.com/dapphub/dapptools;
    rev = "1be7d796a468f52a5eb5b6830591d76a3b4b1c49";
  }) {};

in
  pkgs.mkShell {
    src = null;
    name = "fiat-lux";
    buildInputs = with pkgs; [
      pkgs.dapp
      pkgs.seth
      pkgs.go-ethereum-unlimited
      pkgs.hevm
    ];
  }