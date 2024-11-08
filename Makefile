compile:
	npx hardhat compile

deploy:
	npx hardhat run script/deploy_upgradable.ts --network dbcTestnet

verify:
	source .env && npx hardhat verify --network dbcTestnet $PROXY_CONTRACT

upgrade:
	npx hardhat run script/upgrade.ts --network dbcTestnet
