const fs = require("fs");
const path = require("path");
const solc = require("solc");

const root = path.join(__dirname, "..");
const input = {
  language: "Solidity",
  sources: {
    "src/MultiRewardStaking.sol": {
      content: fs.readFileSync(path.join(root, "src/MultiRewardStaking.sol"), "utf8"),
    },
  },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: {
      "*": {
        "*": ["abi"],
      },
    },
    remappings: ["@openzeppelin/=node_modules/@openzeppelin/"],
  },
};

const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

function findImports(relativePath) {
  const fullPath = path.join(root, relativePath);
  try {
    return { contents: fs.readFileSync(fullPath, "utf8") };
  } catch (e) {
    return { error: "File not found: " + fullPath };
  }
}

if (output.errors) {
  const errs = output.errors.filter((e) => e.severity === "error");
  if (errs.length) {
    console.error(JSON.stringify(errs, null, 2));
    process.exit(1);
  }
}
console.log("OK: MultiRewardStaking compiles with OpenZeppelin remappings.");
