import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const css = await readFile(new URL('../../web/style.css', import.meta.url), 'utf8');
const tokens = await readFile(new URL('../../web/tokens/typography.css', import.meta.url), 'utf8');
const footer = css.match(/aside footer\s*\{([^}]+)\}/g)?.find(rule => /font:/.test(rule));
assert.ok(footer, 'The sidebar username has a dedicated footer rule');
const font = footer.match(/font:\s*var\((--[\w-]+)\)\s+var\(--font-mono\)/);
assert.ok(font, 'The sidebar username keeps its monospace font');
const size = tokens.match(new RegExp(`${font[1]}:\\s*(\\d+)px`));
assert.ok(size, 'The username uses an existing typography size token');
assert.equal(Number(size[1]), 14, 'The sidebar username is slightly larger at 14px');
console.log('Sidebar username typography verified: 14px, monospace');
