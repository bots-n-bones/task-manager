import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
let status;
try {
  const output = execFileSync(`${root}node_modules/.bin/supabase`, ['status', '-o', 'env'], {
    cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  });
  status = parseEnv(output);
} catch {
  console.error('Cannot read local Supabase status. Start it with npm run db:start.');
  process.exit(1);
}

const url = status.API_URL;
const key = status.SECRET_KEY ?? status.SERVICE_ROLE_KEY;
if (!url || !key || !['127.0.0.1', 'localhost'].includes(new URL(url).hostname)) {
  console.error('Expected local API_URL and SECRET_KEY (or SERVICE_ROLE_KEY) in CLI status.');
  process.exit(1);
}

const path = `${root}.env`;
let content;
try { content = readFileSync(path, 'utf8'); }
catch (error) {
  if (error.code !== 'ENOENT') throw error;
  content = readFileSync(`${root}.env.example`, 'utf8');
}
for (const [name, value] of Object.entries({ SUPABASE_URL: url, SUPABASE_SECRET_KEY: key })) {
  const line = `${name}=${JSON.stringify(value)}`;
  const pattern = new RegExp(`^${name}=.*$`, 'm');
  content = pattern.test(content) ? content.replace(pattern, () => line) : `${content.trimEnd()}\n${line}\n`;
}
writeFileSync(path, content, { mode: 0o600 });
chmodSync(path, 0o600);
console.log('Local Supabase settings updated in .env; Telegram token preserved.');
