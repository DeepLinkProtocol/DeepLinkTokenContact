import dotenv from 'dotenv';
const { ethers } = require("hardhat");
dotenv.config();

async function main() {
  const contractFactory = await ethers.getContractFactory("DeepLink");
  const contract  = await contractFactory.deploy(process.env.OWNER);
  console.log("Deploying DeepLink... address :  ",await contract.getAddress());
}

main();