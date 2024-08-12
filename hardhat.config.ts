import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ethers" ;
import "@nomicfoundation/hardhat-verify";
import dotenv from 'dotenv';
dotenv.config();

const config: HardhatUserConfig = {
  solidity: "0.8.23",
  networks: {
    bitlayertestnet: {
      url: 'https://testnet-rpc.bitlayer.org', 
      chainId: 200810,
      // accounts: ["b5eb18473a135e9edf076c00df53d76575fa86bca530c7a650921161189a4ac"],
      accounts: [process.env.PRIVATE_KEY],

    },
  },
  etherscan: {
    apiKey: {
      // An API key needs to be written as the hardhat-verify plugin will require it, and the verification will fail if it is not provided.
      // The current bitlayer browser has not yet enabled API key verification, so you can write any random string for now.
      bitlayertestnet: "1234",
      bscTestnet: 'UQVW6HJ4ZV4U75BE2PKIGT7IT14ASHK3G1'

    },
    customChains: [
      {
        network: "bitlayertestnet",
        chainId: 200810,
        urls: {
          apiURL: "https://api-testnet.btrscan.com/scan/api",
          browserURL: "https://testnet.btrscan.com/"
        }
      }
    ]
  }
};

// proxy:0x54d6F84B8337a897238C0C07C2ebbf74fcb087BC
// logic:0x8a26580DA88DB2E88c48E5694B5F0eF634855C4D

export default config;
