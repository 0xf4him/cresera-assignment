const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MultiRewardStaking", function () {
  async function deployFixture() {
    const [owner, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const stakingToken = await MockERC20.deploy("Stake", "STK");
    const rewardToken = await MockERC20.deploy("Reward", "RWD");

    const Staking = await ethers.getContractFactory("MultiRewardStaking");
    const staking = await Staking.deploy(await stakingToken.getAddress(), owner.address);

    const one = ethers.parseEther("1");
    await stakingToken.mint(alice.address, one * 1_000n);
    await stakingToken.mint(bob.address, one * 1_000n);
    await rewardToken.mint(owner.address, one * 10_000n);

    await staking.connect(owner).addRewardToken(await rewardToken.getAddress(), 100);
    await rewardToken.connect(owner).approve(await staking.getAddress(), one * 10_000n);
    await stakingToken.connect(alice).approve(await staking.getAddress(), one * 1_000n);
    await stakingToken.connect(bob).approve(await staking.getAddress(), one * 1_000n);

    return { owner, alice, bob, staking, stakingToken, rewardToken };
  }

  it("prevents zero stake and over-unstake edge cases", async function () {
    const { alice, staking } = await deployFixture();
    await expect(staking.connect(alice).stake(0)).to.be.revertedWithCustomError(staking, "ZeroAmount");
    await expect(staking.connect(alice).unstake(1)).to.be.revertedWithCustomError(staking, "InsufficientBalance");
  });

  it("handles late joiners and pro-rata distribution correctly", async function () {
    const { owner, alice, bob, staking, rewardToken } = await deployFixture();
    const one = ethers.parseEther("1");

    await staking.connect(owner).fundReward(await rewardToken.getAddress(), one * 1_000n);
    await staking.connect(alice).stake(one * 100n);

    await time.increase(50);
    await staking.connect(bob).stake(one * 100n);
    await time.increase(50);

    const aliceBefore = await rewardToken.balanceOf(alice.address);
    const bobBefore = await rewardToken.balanceOf(bob.address);

    await staking.connect(alice).claimRewards();
    await staking.connect(bob).claimRewards();

    const aliceAfter = await rewardToken.balanceOf(alice.address);
    const bobAfter = await rewardToken.balanceOf(bob.address);

    const aliceClaim = aliceAfter - aliceBefore;
    const bobClaim = bobAfter - bobBefore;
    const totalClaim = aliceClaim + bobClaim;

    expect(aliceClaim).to.be.gt(one * 700n);
    expect(aliceClaim).to.be.lt(one * 800n);
    expect(bobClaim).to.be.gt(one * 200n);
    expect(bobClaim).to.be.lt(one * 300n);
    expect(totalClaim).to.be.lte(one * 1_000n);

    await staking.connect(alice).claimRewards();
    expect(await rewardToken.balanceOf(alice.address)).to.equal(aliceAfter);
  });

  it("does not retroactively allocate rewards when total supply was zero", async function () {
    const { owner, alice, staking, rewardToken } = await deployFixture();
    const one = ethers.parseEther("1");

    await staking.connect(owner).fundReward(await rewardToken.getAddress(), one * 1_000n);
    await time.increase(40);
    await staking.connect(alice).stake(one * 100n);
    await time.increase(60);

    await staking.connect(alice).claimRewards();
    const claim = await rewardToken.balanceOf(alice.address);
    expect(claim).to.be.gt(one * 550n);
    expect(claim).to.be.lte(one * 600n);
  });

  it("rolls leftover rewards into the next funding call", async function () {
    const { owner, alice, staking, rewardToken } = await deployFixture();
    const one = ethers.parseEther("1");

    await staking.connect(alice).stake(one * 100n);
    await staking.connect(owner).fundReward(await rewardToken.getAddress(), one * 1_000n);
    await time.increase(40);

    await staking.connect(owner).fundReward(await rewardToken.getAddress(), one * 500n);
    await time.increase(100);

    await staking.connect(alice).claimRewards();
    const claim = await rewardToken.balanceOf(alice.address);
    expect(claim).to.be.gt(one * 1_400n);
    expect(claim).to.be.lte(one * 1_540n);
  });

  it("blocks reentrancy attempts during reward transfers", async function () {
    const [owner, alice] = await ethers.getSigners();
    const one = ethers.parseEther("1");

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const stakingToken = await MockERC20.deploy("Stake", "STK");
    await stakingToken.mint(alice.address, one * 1_000n);

    const ReentrantRewardToken = await ethers.getContractFactory("ReentrantRewardToken");
    const rewardToken = await ReentrantRewardToken.deploy();
    await rewardToken.mint(owner.address, one * 10_000n);

    const Staking = await ethers.getContractFactory("MultiRewardStaking");
    const staking = await Staking.deploy(await stakingToken.getAddress(), owner.address);

    await rewardToken.setStaking(await staking.getAddress());
    await staking.connect(owner).addRewardToken(await rewardToken.getAddress(), 100);
    await rewardToken.connect(owner).approve(await staking.getAddress(), one * 10_000n);
    await stakingToken.connect(alice).approve(await staking.getAddress(), one * 1_000n);

    await staking.connect(alice).stake(one * 100n);
    await staking.connect(owner).fundReward(await rewardToken.getAddress(), one * 1_000n);
    await time.increase(10);

    await rewardToken.setShouldReenter(true);
    await expect(staking.connect(alice).claimRewards()).to.be.reverted;
  });

  it("reverts when adding the same reward token twice", async function () {
    const { owner, staking, rewardToken } = await deployFixture();
    await expect(
      staking.connect(owner).addRewardToken(await rewardToken.getAddress(), 100)
    ).to.be.revertedWithCustomError(staking, "RewardTokenAlreadyAdded");
  });

  it("reverts fundReward for unknown token", async function () {
    const { owner, staking } = await deployFixture();
    const [, , , random] = await ethers.getSigners();
    await expect(
      staking.connect(owner).fundReward(random.address, 1n)
    ).to.be.revertedWithCustomError(staking, "RewardTokenNotFound");
  });

  it("setRewardsDuration reverts while period active, succeeds after it ends", async function () {
    const { owner, alice, staking, rewardToken } = await deployFixture();
    const one = ethers.parseEther("1");

    await staking.connect(owner).fundReward(await rewardToken.getAddress(), one * 100n);
    await expect(
      staking.connect(owner).setRewardsDuration(await rewardToken.getAddress(), 200)
    ).to.be.revertedWithCustomError(staking, "PeriodStillActive");

    await time.increase(101);
    await staking.connect(owner).setRewardsDuration(await rewardToken.getAddress(), 200);
    const schedule = await staking.rewardSchedules(await rewardToken.getAddress());
    expect(schedule.duration).to.equal(200);
  });
});
