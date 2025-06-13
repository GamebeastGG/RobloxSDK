const Redis = require('ioredis');
const fs = require('fs');
const path = require('path');

const redis = new Redis();

function parseDirectory(dirPath, deep) {
  const result = {};

  const items = fs.readdirSync(dirPath, { withFileTypes: true });

  for (const item of items) {
    if (!deep) {

        console.log(`Processing: ${item.name}`); // Log the item being processed
    }
    const fullPath = path.join(dirPath, item.name);

    if (item.isDirectory()) {
      result[item.name] = parseDirectory(fullPath);
    } else if (item.isFile() && (item.name.endsWith('.lua') || item.name.endsWith('.luau'))) {
      const content = fs.readFileSync(fullPath, 'utf-8');
      result[item.name] = content;
    }
  }

  return result;
}

// Replace './src' with the root directory you want to parse
const rootDir = process.cwd() + "/src"; // Use current working directory
const parsed = parseDirectory(rootDir);

redis.set("latestSdkSourceCode", JSON.stringify({"worked" : true, "source" : parsed}, null))