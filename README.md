# <h1 align="center"> FIAT 🌅 </h1>

**Repository containing the core smart contracts of FIAT**

## Requirements
This repository uses Foundry for building and testing and Solhint for formatting the contracts.
If you do not have Foundry already installed, you'll need to run the commands below.

### Install Foundry
```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Set .env
Copy and update contents from `.env.example` to `.env`

## Tests

After installing dependencies with `make`, run `make test` to run the tests.

## Building and testing

```sh
git clone https://github.com/fiatdao/fiat
cd fiat
make # This installs the project's dependencies.
make test
```
