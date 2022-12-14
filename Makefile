# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Update dependencies
install         :; forge install
update          :; forge update

# Build & test
build           :; forge build # --sizes
clean           :; forge clean
lint            :; yarn install && yarn run lint
test            :; forge test
test-core    	  :; forge test --match-path "**/test/core/**/*.t.sol"
test-actions    :; forge test --match-path "**/test/actions/**/*.t.sol"
test-vaults    	:; forge test --match-path "**/test/vaults/**/*.t.sol"
test-guards    	:; forge test --match-path "**/test/guards/**/*.t.sol"