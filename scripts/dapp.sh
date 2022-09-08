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
  export ETH_RPC_URL=http://localhost:8545
elif [ "$1" == "mainnet" ]; then
  export DAPP_TEST_NUMBER=13627845
  export DAPP_TEST_CACHE=.cache/mainnet-${DAPP_TEST_NUMBER}
  export ETH_RPC_URL=https://eth-$1.alchemyapi.io/v2/${ALCHEMY_API_KEY}
else
  export ETH_RPC_URL=https://eth-$1.alchemyapi.io/v2/${ALCHEMY_API_KEY}
fi

set +o nounset
if [ -n "$DAPP_TEST_CACHE" ]; then
  if [ ! -d ${DAPP_TEST_CACHE} ]; then
    dapp --make-cache ${DAPP_TEST_CACHE};
  fi
fi
set -o nounset

# dapp debug
# seth run-tx $(tx) --source out/dapp.sol.json --debug
eval $2