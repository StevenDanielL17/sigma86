-include .env

.PHONY: all test build deploy-sepolia deploy-arb-sepolia deploy-anvil verify

all: build

build:
	forge build

test:
	forge test -vvv

test-adversarial:
	forge test --match-contract Sigma86AdversarialTest -vvv

test-institutional:
	forge test --match-contract Sigma86InstitutionalTest -vvv

deploy-anvil:
	forge script script/DeploySigma86Vault.s.sol:DeploySigma86Vault --rpc-url http://127.0.0.1:8545 --broadcast

deploy-sepolia:
	forge script script/DeploySigma86Vault.s.sol:DeploySigma86Vault \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		-vvvv

deploy-arb-sepolia:
	forge script script/DeploySigma86Vault.s.sol:DeploySigma86Vault \
		--rpc-url $(ARBITRUM_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ARBISCAN_API_KEY) \
		-vvvv
