import {createHash} from 'node:crypto';
import {database,rpc} from '../server/db.mjs';
import {setTimeout as delay} from 'node:timers/promises';
import {render} from './ui.mjs';
import {handleFile,getAttachment} from './files.mjs';
import {runNotifications} from './notifications.mjs';

const {TELEGRAM_BOT_TOKEN: token, SUPABASE_URL:url, SUPABASE_SECRET_KEY:key, TELEGRAM_ALLOWED_IDS:ids=''}=process.env;
if (!token || !url || !key) throw new Error('Configure connection settings in .env');
const allowed=new Set(ids.split(',').map(id=>id.trim()).filter(Boolean));
if ([...allowed].some(id=>!/^\d+$/.test(id))) throw new Error('Invalid TELEGRAM_ALLOWED_IDS');

async function telegram(method,params={}) {
  const res=await fetch('https://api.telegram.org/bot'+token+'/'+method,{
    method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(params),signal:AbortSignal.timeout(45000)
  });
  const body=await res.json();
  if (!body.ok) throw Object.assign(new Error(method+' HTTP '+body.error_code),{code:body.error_code,retry:body.parameters?.retry_after});
  return body.result;
}

async function handle(update) {
  const cb=update.callback_query;
  const msg=cb?.message ?? update.message;
  const actor=cb?.from ?? msg?.from;
  if (!msg || msg.chat.type!=='private' || actor?.id!==msg.chat.id || actor.is_bot) return;
  if (cb) await telegram('answerCallbackQuery',{callback_query_id:cb.id}).catch(()=>{});
  const send=async payload=>{
    try { await telegram('sendMessage',{chat_id:actor.id,...payload}); }
    catch(error) { if (error.code!==403) throw error; }
  };
  if (!cb && /^\/link [A-Za-z0-9_-]{32}$/.test(msg.text ?? '')) {
    if(!await rpc('login_limit',{p_key:'telegram-link:'+actor.id}))return send({text:'Try linking again in 15 minutes.'});
    try {
      await rpc('consume_link_code',{p_actor:actor.id,p_hash:createHash('sha256').update(msg.text.slice(6)).digest('hex')});
      return send({text:'Telegram linked. Send /start.'});
    }catch(error){if([403,409].includes(error.status))return send({text:'The code is invalid or the profile is already linked.'});throw error;}
  }
  if(process.env.EMAIL_ONLY==='true')return send({text:'Open the app to manage tasks.',reply_markup:{inline_keyboard:[[{text:'Tasks',web_app:{url:process.env.APP_ORIGIN}}]]}});
  const profiles=await database('/rest/v1/users?select=active&telegram_id=eq.'+actor.id);
  if (profiles.length ? !profiles[0].active : !allowed.has(String(actor.id)))
    return send({text:'Access denied. Use /link with the code from your website profile.'});
  if (!cb && (msg.document || msg.photo)) {
    return send(render(await handleFile({msg,actor,update,telegram,url,key})));
  }
  let action='text', value=msg.text ?? '';
  if (cb) {
    if (!/^(project_open|project_delete|project_delete_confirm|project_team|task_team|admin_pick|admin_save|filters|all_status|all_member|all_project|attachment|edit|project_new|archive|restore|today|overdue|pick|flag|next|create|menu|projects|list|all|open|begin|result|skip|save|back|abort|approve|return|cancel_task)(:[a-z0-9-]+(?::[a-z0-9-]+)?)?$/.test(cb.data ?? '')) return;
    const [key,...parts]=cb.data.split(':');
    action=key; value=parts.join(':');
  } else if (/^\/start(?:\s|$)/.test(value)) action='start';
  else if (value==='/cancel') action='cancel';
  else if (!msg.text) return send({text:'Send a text message.'});
  if (action==='attachment') {
    const file=await getAttachment({actor,id:value,url,key});
    if (!file) return send({text:'Attachment unavailable.'});
    if(!file.telegram_file_id){
      const response=await fetch(new URL('/storage/v1/object/authenticated/task-results/'+file.storage_path,url),{
        headers:{apikey:key,Authorization:'Bearer '+key},signal:AbortSignal.timeout(45000)});
      if(!response.ok)throw new Error('Storage download HTTP '+response.status);
      const form=new FormData();form.set('chat_id',String(actor.id));form.set('document',await response.blob(),file.name);
      const sent=await fetch('https://api.telegram.org/bot'+token+'/sendDocument',{method:'POST',body:form,signal:AbortSignal.timeout(45000)});
      const result=await sent.json();if(!result.ok && result.error_code!==403)throw new Error('sendDocument HTTP '+result.error_code);
      return;
    }
    try { await telegram(file.telegram_kind==='photo'?'sendPhoto':'sendDocument',{chat_id:actor.id,[file.telegram_kind==='photo'?'photo':'document']:file.telegram_file_id}); }
    catch(error) { if(error.code!==403) throw error; }
    return;
  }
  const res=await fetch(new URL('/rest/v1/rpc/bot_event',url),{
    method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'content-type':'application/json'},
    body:JSON.stringify({p_update:update.update_id,p_actor:actor.id,p_name:({vanya:'Vanya',ilya:'Ilya'})[actor.first_name?.toLowerCase()] ?? (actor.first_name || String(actor.id)),p_action:action,p_value:value}),
    signal:AbortSignal.timeout(10000)
  });
  if (!res.ok) throw new Error('Supabase HTTP '+res.status);
  await send(render(await res.json()));
}

const me=await telegram('getMe');
const hook=await telegram('getWebhookInfo');
if (hook.url) throw new Error('Disable the existing webhook to use long polling.');
if(process.env.APP_ORIGIN?.startsWith('https://')){
  await telegram('setChatMenuButton',{menu_button:{type:'web_app',text:'Tasks',web_app:{url:process.env.APP_ORIGIN}}});
}
console.log('Bot @'+me.username+' started. Allowed IDs: '+allowed.size);
void runNotifications({telegram,allowed,url,key});
let offset;
for (;;) {
  try {
    const updates=await telegram('getUpdates',{offset,timeout:30,allowed_updates:['message','callback_query']});
    for (const update of updates) {
      await handle(update);
      offset=update.update_id+1;
    }
  } catch(error) {
    console.error('Retry after error:',error.message);
    await delay(1000*Math.max(3,error.retry ?? 0));
  }
}
