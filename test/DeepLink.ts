 import { expect } from "chai";
  import hre from "hardhat";
  
  describe("DeepLink", function () {
    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    async function deployFixture() {
      // Contracts are deployed using the first signer/account by default
      const [owner,otherAccount] = await hre.ethers.getSigners();
  
      const cf = await hre.ethers.getContractFactory("DeepLink");
      const deepLinkContract = await cf.deploy(owner);
  
      return { deepLinkContract, owner,otherAccount };
    }

    describe("Deployment", function () {
        it("Should deploy the contract with the owner as the deployer", async function () {
            const { deepLinkContract, owner } = await deployFixture();
            expect(await deepLinkContract.owner() ).to.equal(owner.address);
        })    
    })
    // todo
  });