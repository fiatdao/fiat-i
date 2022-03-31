# <h1 align="center"> FIAT 🌅 </h1>

**Repository containing the core smart contracts of FIAT**

## Requirements

Having installed [Foundry](https://github.com/gakonst/foundry) and [Node.js](https://nodejs.org/) is the minimum requirement to get started.

Run `make` to install dependencies.

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

## Deploying contracts
```sh
# local
make testnet
# in another shell
make deploy-local
```
