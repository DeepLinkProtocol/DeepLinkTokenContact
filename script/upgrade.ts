const { ethers, upgrades } = require("hardhat");

async function upgrade() {
    const contract = await ethers.getContractFactory("Token");

    await upgrades.upgradeProxy(
        process.env.PROXY_CONTRACT,
        contract
    );
    console.log("contract upgraded");
}

upgrade();