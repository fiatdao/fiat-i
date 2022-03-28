#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

if [ -d .env ]; then
  set -o allexport; source .env; set +o allexport
fi

if [ -z "$ALCHEMY_API_KEY" ]; then
  echo "ALCHEMY_API_KEY is undefined in .env";
  exit 1;
fi

networks=(local mainnet goerli)
if [[ ! " ${networks[*]} " =~ " $1 " ]]; then 
  echo "Unsupported network '$1'";
  exit 1;
fi

if [ "$1" == "local" ]; then
  ETH_RPC_URL=http://localhost:8545
elif [ "$1" == "mainnet" ]; then
  DAPP_TEST_NUMBER=13627845
  DAPP_TEST_CACHE=.cache/mainnet-${DAPP_TEST_NUMBER}
  ETH_RPC_URL=https://eth-$1.alchemyapi.io/v2/${ALCHEMY_API_KEY}
  forge test --fork-url $ETH_RPC_URL --fork-block-number $DAPP_TEST_NUMBER
else
  ETH_RPC_URL=https://eth-$1.alchemyapi.io/v2/${ALCHEMY_API_KEY}
  forge test --fork-url $ETH_RPC_URL
fi

