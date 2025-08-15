compile:
	npx hardhat compile
	
deploy-dbc-mainnet:
	source .env && npx hardhat run script/deploy_upgradable.ts --network dbcMainnet

verify-dbc-mainnet:
	source .env && npx hardhat verify --network dbcMainnet $PROXY_CONTRACT

upgrade-dbc-mainnet:
	npx hardhat run script/upgrade.ts --network dbcMainnet
