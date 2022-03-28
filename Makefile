# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Update dependencies
setup			:; make update-libs ; make install-deps
update-libs		:; git submodule update --init --recursive
install-deps	:; yarn install

# Build & test & deploy
build           :; forge build
clean           :; forge clean
lint            :; yarn run lint
# debug           :; ./scripts/run.sh local "dapp debug"
# debug-tx        :; ./scripts/run.sh $(network) "seth run-tx $(tx) --source out/dapp.sol.json --debug"

# This isn't used
# lint            :; yarn run lint
size            :; ./scripts/contract-size.sh ${contract}
snapshot        :; ./scripts/run.sh mainnet "forge snapshot --fork-url ${ETH_RPC_URL} --fork-block-number ${DAPP_TEST_NUMBER}"
test            :
	./scripts/run.sh mainnet
test-fork		:
	./scripts/run.sh $(network)
test-local      :
	./scripts/run.sh local "forge test --ffi --match-path `pwd`/src/test/local --fork-url http://localhost:8545"
