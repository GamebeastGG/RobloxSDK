// Builds the published SDK payload into an output dir, for the deploy workflow to upload to GCS:
//   versions/<version>/source.json  immutable history copy
//   latest/source.json              { worked, version, source } served by GET /sdk/v1/latest/source
//   latest/version.json             { version } served by GET /sdk/v1/latest/version
// Usage: node createSdkSource.js <outDir>
const fs = require('fs');
const path = require('path');

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

function getVersion(fileText) {
  const versionMatch = fileText.match(/version\s*=\s*['"]([^'"]+)['"]/);
  return versionMatch ? versionMatch[1] : null;
}

function writeFile(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents);
}

const outDir = process.argv[2];
if (!outDir) {
  console.error('Usage: node createSdkSource.js <outDir>');
  process.exit(1);
}

const rootDir = path.join(process.cwd(), 'src');
const parsed = parseDirectory(rootDir);
const metaData = parsed.Infra && (parsed.Infra['MetaData.luau'] || parsed.Infra['MetaData.lua']);
const version = metaData && getVersion(metaData);
if (!version) {
  console.error('Could not read the SDK version from src/Infra/MetaData');
  process.exit(1);
}

const source = JSON.stringify({ worked: true, version: version, source: parsed });
console.log('Payload size (bytes):', Buffer.byteLength(source));

writeFile(path.join(outDir, 'versions', version, 'source.json'), source);
writeFile(path.join(outDir, 'latest', 'source.json'), source);
writeFile(path.join(outDir, 'latest', 'version.json'), JSON.stringify({ version: version }));

// Exposed to later workflow steps
if (process.env.GITHUB_OUTPUT) {
  fs.appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\n`);
}
console.log(`Built SDK ${version} into ${outDir}`);
