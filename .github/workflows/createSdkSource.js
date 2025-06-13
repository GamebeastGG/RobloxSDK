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
    const fullPath = path.join(dirPath, item.name)
    
    console.log(`Processing: ${fullPath}`);

    if (item.isDirectory()) {
      result[item.name] = parseDirectory(fullPath);
    } else if (item.isFile() && (item.name.endsWith('.lua') || item.name.endsWith('.luau'))) {
      const content = fs.readFileSync(fullPath, 'utf-8');
      result[item.name] = content;
    }
  }

  return result;
}

(async () => {
  const rootDir = process.cwd() + "/src";
  const parsed = parseDirectory(rootDir);

  const output = JSON.stringify({ worked: true, source: parsed });
  console.log('Payload size (bytes):', Buffer.byteLength(output));

  try {
    const result = await redis.set("latestSdkSourceCode", output);
    console.log('Redis SET result:', result);
    process.exit(0);
  } catch (err) {
    console.error('Redis SET failed:', err);
    process.exit(1);
  }
})();