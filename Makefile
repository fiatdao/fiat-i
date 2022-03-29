# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Update dependencies
setup           :; make update-libs ; make install-deps
update-libs     :; git submodule update --init --recursive
install-deps    :; yarn install

# Build & test & deploy
build           :; forge build
clean           :; forge clean
lint            :; yarn run lint
size            :; ./scripts/contract-size.sh ${contract}
test            :; ./scripts/run.sh mainnet
test-fork       :; ./scripts/run.sh $(network)
test-local      :; ./scripts/run.sh local

# Not migrated to Foundry yet
debug           :; ./scripts/debug.sh local "dapp debug"
debug-tx        :; ./scripts/debug.sh $(network) "seth run-tx $(tx) --source out/dapp.sol.json --debug"
snapshot        :; ./scripts/debug.sh mainnet "forge snapshot --fork-url ${ETH_RPC_URL} --fork-block-number ${DAPP_TEST_NUMBER}"
