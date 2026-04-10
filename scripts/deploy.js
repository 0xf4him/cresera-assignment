const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const owner = process.env.OWNER ?? deployer.address;
  let stakingToken = process.env.STAKING_TOKEN;

  if (!stakingToken) {
    const isLocal = hre.network.name === "hardhat" || hre.network.name === "localhost";
    if (!isLocal) {
      throw new Error(
        "STAKING_TOKEN is required on non-local networks. Set env var STAKING_TOKEN=0x..."
      );
    }

    const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
    const mock = await MockERC20.deploy("Stake Token", "STK");
    await mock.waitForDeployment();
    stakingToken = await mock.getAddress();
    console.log(`Mock staking token deployed: ${stakingToken}`);
  }

  const MultiRewardStaking = await hre.ethers.getContractFactory("MultiRewardStaking");
  const staking = await MultiRewardStaking.deploy(stakingToken, owner);
  await staking.waitForDeployment();

  const stakingAddress = await staking.getAddress();
  console.log(`Network: ${hre.network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Owner: ${owner}`);
  console.log(`Staking token: ${stakingToken}`);
  console.log(`MultiRewardStaking deployed: ${stakingAddress}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
