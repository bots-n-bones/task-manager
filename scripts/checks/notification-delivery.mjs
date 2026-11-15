import assert from 'node:assert/strict';
import {deliverNotification} from '../../bot/notifications.mjs';

const delivery={telegram_id:999,kind:'deadline',attempts:1,tasks:[{number:1,title:'Deadline task',due_date:'2026-11-10'}]};
const calls=[];
assert.equal((await deliverNotification(delivery,async(method,body)=>calls.push({method,body}))).p_status,'sent');
assert.equal(calls.length,1);
assert.equal(calls[0].method,'sendMessage');
assert.equal(calls[0].body.chat_id,999);
assert.equal(calls[0].body.reply_markup.inline_keyboard[0][0].callback_data,'today:0');
assert.ok(calls[0].body.text.includes('Deadline task'));
const blocked=await deliverNotification(delivery,async()=>{throw {code:403};});
assert.equal(blocked.p_status,'unavailable');
const limited=await deliverNotification(delivery,async()=>{throw {code:429,retry:300};});
assert.equal(limited.p_status,'retry');
assert.equal(limited.p_delay,300);
const unknown=await deliverNotification(delivery,async()=>{throw Error('opaque transport failure');});
assert.equal(unknown.p_status,'retry');
assert.equal(unknown.p_error,'Telegram request failed');

const summary={...delivery,kind:'overdue',tasks:Array.from({length:100},(_,i)=>({number:i,title:'x'.repeat(120),due_date:'2026-11-09'}))};
const parts=[];
await deliverNotification(summary,async(method,body)=>parts.push(body));
assert.ok(parts.length>1);
assert.ok(parts.every(body=>body.text.length<4096));
assert.ok(parts.at(-1).text.includes('№99'));
assert.ok(parts.every(body=>body.reply_markup.inline_keyboard[0][0].callback_data==='overdue:0'));
console.log('Notification requests, summaries, 403, 429 and network retries verified');
