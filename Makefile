compile:
	npx hardhat compile

deploy:
	npx hardhat run script/deploy_upgradable.ts --network dbcTestnet

verify:
	npx hardhat verify --network dbcTestnet 0xd6a0843e7c99357ca5bA3525A0dB92F8E5817c07

upgrade:
	npx hardhat run script/upgrade.ts --network dbcTestnet
