const Redis = require('ioredis');
const fs = require('fs');
const path = require('path');

const redis = new Redis();

redis.on('connect', () => console.log('Redis connected'));
redis.on('error', (err) => {
  console.error('Redis error:', err);
  process.exit(1);
});

function parseDirectory(dirPath) {
  const result = {};

  const items = fs.readdirSync(dirPath, { withFileTypes: true });

  for (const item of items) {
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

const rootDir = process.cwd() + "/src";
const parsed = parseDirectory(rootDir);

redis.set("latestSdkSourceCode", JSON.stringify({"worked" : true, "source" : parsed}, null))