import {createHash,createHmac,randomBytes,timingSafeEqual} from 'node:crypto';
import {database,rpc} from './db.mjs';
export const hash=value=>createHash('sha256').update(value).digest('hex');
export function validateTelegram(raw,token,now=Date.now()) {
  if(typeof raw!=='string' || raw.length>12000) throw new Error('Invalid Telegram data');
  const params=new URLSearchParams(raw);
  if(new Set(params.keys()).size!==[...params.keys()].length) throw new Error('Duplicate Telegram fields');
  const signature=params.get('hash');
  if(!/^[a-f0-9]{64}$/.test(signature ?? '')) throw new Error('Invalid Telegram signature');
  params.delete('hash');
  const data=[...params.entries()].sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,v])=>k+'='+v).join('\n');
  const secret=createHmac('sha256','WebAppData').update(token).digest();
  const expected=createHmac('sha256',secret).update(data).digest();
  if(!timingSafeEqual(expected,Buffer.from(signature,'hex'))) throw new Error('Invalid Telegram signature');
  const date=Number(params.get('auth_date'));
  if(!Number.isSafeInteger(date) || now/1000-date>300 || date>now/1000+30) throw new Error('Expired Telegram data');
  const user=JSON.parse(params.get('user') ?? 'null');
  if(!Number.isSafeInteger(user?.id) || user.id<=0) throw new Error('Invalid Telegram user');
  return user.id;
}
export async function createSession(user,response,secure,emailLogin=false) {
  const token=randomBytes(32).toString('base64url');
  await database('/rest/v1/web_sessions',{method:'POST',body:{email_login:emailLogin,token_hash:hash(token),user_id:user.id,expires_at:new Date(Date.now()+86400000).toISOString()}});
  response.setHeader('Set-Cookie','session='+token+'; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400'+(secure?'; Secure':''));
}
export async function currentUser(request) {
  const token=(request.headers.cookie ?? '').split(';').map(x=>x.trim()).find(x=>x.startsWith('session='))?.slice(8);
  if(!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
  const sessions=await database('/rest/v1/web_sessions?select=user_id&token_hash=eq.'+hash(token)+(process.env.EMAIL_ONLY==='true'?'&email_login=eq.true':'')+'&expires_at=gt.'+encodeURIComponent(new Date().toISOString()));
  if(!sessions.length) return null;
  const users=await database('/rest/v1/users?select=id,name,role,telegram_id,login,active&id=eq.'+sessions[0].user_id+'&active=eq.true');
  return users[0] ?? null;
}
export async function rateLimit(key) {
  return rpc('login_limit',{p_key:hash(key)});
}
