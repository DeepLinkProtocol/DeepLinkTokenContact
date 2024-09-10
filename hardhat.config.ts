import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ethers" ;
import "@nomicfoundation/hardhat-verify";
import dotenv from 'dotenv';
dotenv.config();

require('@openzeppelin/hardhat-upgrades');


const config: HardhatUserConfig = {
  solidity: "0.8.20",
  sourcify: {
    // Enable Sourcify verification by default
    enabled: true,
  },
  networks: {
    bitlayertestnet: {
      url: 'https://testnet-rpc.bitlayer.org',
      chainId: 200810,
      // accounts: ["b5eb18473a135e9edf076c00df53d76575fa86bca530c7a650921161189a4ac"],
      accounts: [process.env.PRIVATE_KEY],
    },
    bscTestnet :{
      url: 'https://data-seed-prebsc-1-s3.binance.org:8545',
      chainId: 97,
      accounts: [process.env.BSC_PRIVATE_KEY],
    },
    dbcTestnet: {
      url: 'https://rpc-testnet.dbcwallet.io',
      accounts: [process.env.DBC_TEST_PRIVATE_KEY],

      // accounts: {
      //   mnemonic: process.env.DBC_TEST_MNEMONIC || '',
      // },
      chainId: 19850818,
      timeout: 600000,
    },
    dbcMainnet: {
      url: 'https://rpc.dbcwallet.io',
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
      chainId: 19880818,
      timeout: 600000,
    }
  },
  etherscan: {
    apiKey: {
      dbcTestnet: 'no-api-key-needed',
      dbcMainnet: 'no-api-key-needed',
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
      },
      {
        network: "dbcTestnet",
        chainId: 19850818,
        urls: {
          apiURL: "https://blockscout-testnet.dbcscan.io/api",
          browserURL: "https://blockscout-testnet.dbcscan.io",
        },
      },
      {
        network: "dbcMainnet",
        chainId: 19880818,
        urls: {
          apiURL: "https://blockscout.dbcscan.io/api",
          browserURL: "https://blockscout.dbcscan.io",
        },
      }
    ]
  }
};



export default config;
