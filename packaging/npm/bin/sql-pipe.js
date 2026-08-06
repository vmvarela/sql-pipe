#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');

const BINARIES = {
  'linux-x64': 'sql-pipe-linux-x64',
  'linux-arm64': 'sql-pipe-linux-arm64',
  'linux-arm': 'sql-pipe-linux-arm',
  'darwin-x64': 'sql-pipe-darwin-x64',
  'darwin-arm64': 'sql-pipe-darwin-arm64',
  'win32-x64': 'sql-pipe-win32-x64.exe',
};

const key = `${process.platform}-${process.arch}`;
const binary = BINARIES[key];

if (!binary) {
  const supported = Object.keys(BINARIES).join(', ');
  console.error(
    `sql-pipe: unsupported platform "${key}". Supported platforms: ${supported}`
  );
  process.exit(1);
}

const result = spawnSync(
  path.join(__dirname, binary),
  process.argv.slice(2),
  { stdio: 'inherit' }
);

if (result.error) {
  console.error(`sql-pipe: failed to run binary: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status === null ? 1 : result.status);