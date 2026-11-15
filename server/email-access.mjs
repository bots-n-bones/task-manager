import nodemailer from 'nodemailer';
import {createHash,randomBytes} from 'node:crypto';
import {database} from './db.mjs';
import {auth} from './accounts.mjs';

export const emailOnly = process.env.EMAIL_ONLY === 'true';
export function corporateEmail(value) {
  const email = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return email.length <= 254 && /^[a-z0-9._%+-]+@bots-n-bones\.com$/.test(email) ? email : null;
}
const digest = value => createHash('sha256').update(value).digest('hex');
const fail = status => Object.assign(new Error('Account is unavailable'),{status});
const patch = (id,body,condition='') => database('/rest/v1/users?id=eq.'+id+condition,{
  method:'PATCH',body,headers:{Prefer:'return=representation'}
});
const transport = nodemailer.createTransport({
  host:process.env.SMTP_HOST || 'smtp-relay.gmail.com',port:587,secure:false,requireTLS:true,
  name:'tasks.molotilka.site',connectionTimeout:8000,socketTimeout:15000
});

const pendingMail=new Set();
export async function issueAccess(id,address,kind,mailer=transport) {
  if(pendingMail.has(id)) throw fail(409);
  pendingMail.add(id);
  try {return await deliver(id,address,kind,mailer);}
  finally {pendingMail.delete(id);}
}

async function deliver(id,address,kind,mailer) {
  const email=corporateEmail(address);
  if (!email || !/^[a-f0-9-]{36}$/.test(id)) throw fail(400);
  const [user]=await patch(id,{corporate_email:email},
    '&active=eq.true&or=(corporate_email.is.null,corporate_email.eq.'+encodeURIComponent(email)+')');
  if (!user || (kind==='invite')===user.email_activated) throw fail(409);
  // The application links Supabase tokens to a specific profile and a purpose-specific expiry.
  let authEmail=email;
  if (user.auth_id) authEmail=(await auth('admin/users/'+user.auth_id,undefined,undefined,'GET')).email;
  else {
    // Fixed ID makes creation retryable when the profile update or SMTP delivery fails.
    try {
      await auth('admin/users',{id:user.id,email,password:randomBytes(32).toString('hex'),email_confirm:true});
    } catch(error) {
      const existing=await auth('admin/users/'+user.id,undefined,undefined,'GET').catch(()=>null);
      if (existing?.email!==email) throw error;
    }
    await patch(id,{auth_id:user.id},'&auth_id=is.null');
  }
  const link=await auth('admin/generate_link',{email:authEmail,type:'recovery'});
  if ((link.user?.id ?? link.id)!==(user.auth_id ?? id)) throw fail(409);
  const token=link.hashed_token, hash=digest(token);
  const expires=new Date(Date.now()+(kind==='invite'?24:1)*3600000).toISOString();
  const invite=kind==='invite';
  await patch(id,{access_token_hash:hash,access_token_expiry:expires,access_mail_status:invite?'issued':'sending'});
  if(invite) return {code:token,expiresAt:expires};
  const url=new URL(process.env.APP_ORIGIN);
  url.hash=new URLSearchParams({code:token,action:kind}).toString();
  try {
    await mailer.sendMail({from:'BnB Task Manager <provider@bots-n-bones.com>',to:email,
      subject:'BnB Task Manager password reset',
      text:'To reset your password, open this link within one hour.'+'\n\n'+url.href});
  } catch {
    await patch(id,{access_mail_status:'failed'},'&access_token_hash=eq.'+hash);
    throw fail(502);
  }
  await patch(id,{access_mail_status:'sent'},'&access_token_hash=eq.'+hash);
  return {ok:true};
}

export async function recover(address) {
  const email=corporateEmail(address);
  if (!email) return;
  const [u]=await database('/rest/v1/users?select=id&active=eq.true&email_activated=eq.true&corporate_email=eq.'+encodeURIComponent(email));
  if(u) await issueAccess(u.id,email,'recovery');
}

export async function finishAccess({code,password}) {
  if(typeof code!=='string'||!/^[a-f0-9]{40,128}$/.test(code)||typeof password!=='string'||password.length<12||password.length>256) throw fail(400);
  const hash=digest(code);
  const [u]=await database('/rest/v1/users?select=id,auth_id,corporate_email&active=eq.true&access_token_hash=eq.'+hash+'&access_token_expiry=gt.'+encodeURIComponent(new Date().toISOString()));
  if(!u) throw fail(422);
  const verified=await auth('verify',{token_hash:code,type:'recovery'});
  if(verified.user.id!==u.auth_id) throw fail(403);
  await auth('admin/users/'+u.auth_id,{email:u.corporate_email,email_confirm:true,password},undefined,'PUT');
  await database('/rest/v1/web_sessions?user_id=eq.'+u.id,{method:'DELETE'});
  await patch(u.id,{email_activated:true,access_mail_status:'activated',access_token_hash:null,access_token_expiry:null});
  return {ok:true};
}
