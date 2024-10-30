compile:
	npx hardhat compile

deploy:
	npx hardhat run script/deploy_upgradable.ts --network dbcTestnet

verify:
	npx hardhat verify --network dbcTestnet 0x169343c310822b15BAC19F9Cd5aD3C7041575f94

upgrade:
	npx hardhat run script/upgrade.ts --network dbcTestnet
