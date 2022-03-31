# <h1 align="center"> FIAT 🌅 </h1>

**Repository containing the core smart contracts of FIAT**

## Requirements
This repository uses Foundry for building and testing the contracts, Node.js for linting and DappTools for
debugging contracts. If you do not have Foundry or DappTools already installed, you'll need to run the 
commands below.

### Install Foundry
```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install Nix (prerequisite for installing DappTools)

```sh
# User must be in sudoers
curl -L https://nixos.org/nix/install | sh

# Run this or login again to use Nix
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
```

### Install DappTools (for debugging only)
```sh
nix-env -f https://github.com/dapphub/dapptools/archive/f9ff55e11100b14cd595d8c15789d8407124b349.tar.gz -iA dapp hevm seth ethsign
```

## Tests

After installing dependencies with `make`, run `make test` to run the tests.

### Set .env
Copy and update contents from `.env.example` to `.env`

## Building and testing

```sh
git clone https://github.com/fiatdao/fiat
cd fiat
make # This installs the project's dependencies.
make test
```
