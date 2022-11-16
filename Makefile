# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Update dependencies
install         :; forge install
update          :; forge update

# Build & test
build           :; forge build
clean           :; forge clean
lint            :; yarn install && yarn run lint
test            :; forge test
test-mainnet    :; forge test --match-path "**/test/rpc/**/*.t.sol"
test-local      :; forge test --match-path "**/test/local/**/*.t.sol"

