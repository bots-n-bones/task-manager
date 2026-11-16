import {deleteMember,runMemberCleanup} from './member-deletion.mjs';
import {runStorageCleanup} from './storage-cleanup.mjs';
import {uploadResult,downloadFile} from './files.mjs';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {corporateEmail,emailOnly,issueAccess,recover,finishAccess} from './email-access.mjs';
import {randomBytes} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {database,rpc} from './db.mjs';
import {createSession,currentUser,hash,rateLimit,validateTelegram} from './auth.mjs';
const origin=process.env.APP_ORIGIN ?? 'http://127.0.0.1:3000';
const secure=new URL(origin).protocol==='https:';
async function json(request) {
  let body='';
  for await(const chunk of request) {
    body+=chunk;
    if(Buffer.byteLength(body)>16000) throw Object.assign(new Error('Request too large'),{status:413});
  }
  try{return JSON.parse(body);}catch{throw Object.assign(new Error('Invalid JSON'),{status:400});}
}
const server=createServer(async(req,res)=>{
  res.setHeader('Content-Type','application/json; charset=utf-8');
  res.setHeader('Cache-Control','no-store');
  res.setHeader('X-Content-Type-Options','nosniff');
  const reply=(status,data)=>{res.writeHead(status);res.end(JSON.stringify(data));};
  try {
    if(req.method!=='GET' && req.headers.origin!==origin) return reply(403,{error:'Origin rejected'});
    const designToken=/^\/tokens\/(base|colors|fonts|motion|spacing|typography)\.css$/.test(req.url);
    if(req.method==='GET' && (designToken || ['/', '/app.js','/browser.mjs','/style.css','/bnb-logo.png'].includes(req.url))){
      const file=req.url==='/'?'index.html':req.url.slice(1);
      const types={'index.html':'text/html; charset=utf-8','app.js':'text/javascript; charset=utf-8','browser.mjs':'text/javascript; charset=utf-8','style.css':'text/css; charset=utf-8','bnb-logo.png':'image/png'};
      res.setHeader('Content-Type',designToken?types['style.css']:types[file]);
      res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self' https://telegram.org; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; connect-src 'self'; frame-ancestors 'self' https://web.telegram.org https://*.telegram.org");
      res.end(await readFile(new URL('../web/'+file,import.meta.url)));return;
    }
    if(req.method==='GET' && req.url==='/health') return reply(200,{ok:true});
    if(req.method==='GET' && req.url==='/api/access-mode') return reply(200,{emailOnly});
    if(req.method==='POST' && req.url==='/api/recover') {
      const {email}=await json(req);
      if(await rateLimit('reset-ip:'+req.socket.remoteAddress) && await rateLimit('reset:'+corporateEmail(email))) {
        void recover(email).catch(()=>console.error('Recovery delivery failed'));
      }
      return reply(200,{ok:true});
    }
    if(req.method==='POST' && ['/api/login','/api/telegram'].includes(req.url)){
      if(!await rateLimit('ip:'+req.socket.remoteAddress)) return reply(429,{error:'Try signing in again in 15 minutes.'});
      const body=await json(req);
      let user;
      if(req.url==='/api/login'){
        const login=corporateEmail(body.email);
        if(!login || typeof body.password!=='string' || body.password.length>256)
          return reply(401,{error:'Incorrect email or password.'});
        if(!await rateLimit('login:'+login)) return reply(429,{error:'Try signing in again in 15 minutes.'});
        const auth=await fetch(new URL('/auth/v1/token?grant_type=password',process.env.SUPABASE_URL),{
          method:'POST',headers:{apikey:process.env.SUPABASE_SECRET_KEY,'content-type':'application/json'},
          body:JSON.stringify({email:login,password:body.password}),signal:AbortSignal.timeout(15000)});
        if(!auth.ok) return reply(401,{error:'Incorrect email or password.'});
        const data=await auth.json();
        [user]=await database('/rest/v1/users?select=id,name,role,telegram_id,login&active=eq.true&email_activated=eq.true&auth_id=eq.'+data.user.id);
      }else{
        if(emailOnly) return reply(403,{error:'Sign in with your work email.'});
        let id;
        try{id=validateTelegram(body.initData,process.env.TELEGRAM_BOT_TOKEN);}catch{return reply(401,{error:'Invalid Telegram credentials.'});}
        [user]=await database('/rest/v1/users?select=id,name,role,telegram_id,login&active=eq.true&telegram_id=eq.'+id);
      }
      if(!user) return reply(401,{error:'Account unavailable.'});
      await createSession(user,res,secure,req.url==='/api/login');
      return reply(200,{user});
    }
    if(req.method==='POST' && req.url==='/api/setup'){
      if(!await rateLimit('setup:'+req.socket.remoteAddress)) return reply(429,{error:'Try again later.'});
      return reply(200,await finishAccess(await json(req)));
    }
    const user=await currentUser(req);
    if(!user) return reply(401,{error:'Sign-in required.'});
    if(req.url==='/api/link-code' && req.method==='POST'){
      const code=randomBytes(24).toString('base64url');
      await rpc('issue_link_code',{p_user:user.id,p_hash:hash(code)});
      return reply(200,{code,expiresIn:900});
    }
    if(req.url==='/api/members' && req.method==='POST'){
      const body=await json(req);
      return reply(200,{member:await rpc('create_member',{p_admin:user.id,p_name:body.name})});
    }
    if(req.url==='/api/accounts' && req.method==='GET'){
      if(user.role!=='admin') return reply(403,{error:'Administrator access required.'});
      return reply(200,{members:await database('/rest/v1/users?select=id,name,corporate_email,email_activated,access_mail_status,role,active,telegram_id&deleted_at=is.null&order=name')});
    }
    if(req.url==='/api/accounts' && req.method==='DELETE'){
      if(user.role!=='admin')return reply(403,{error:'Administrator access required.'});
      const body=await json(req),uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
      if(!uuid.test(body.userId ?? '')||!uuid.test(body.successorId ?? ''))return reply(400,{error:'Select an active administrator to take over.'});
      try{
        const result=await deleteMember(user.id,body.userId,body.successorId);
        if(body.userId===user.id)res.setHeader('Set-Cookie','session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'+(secure?'; Secure':''));
        return reply(200,result);
      }
      catch(error){return reply(error.status ?? 502,{error:error.status===422?'Choose another active administrator before deleting this member.':error.status===403?'Administrator access required.':'Could not delete the member. Refresh Members and try again.'});}
    }
    if(req.url==='/api/accounts' && req.method==='PATCH'){
      if(user.role!=='admin') return reply(403,{error:'Administrator access required.'});
      const body=await json(req);
      if ((body.active!==undefined && typeof body.active!=='boolean') || (body.role!==undefined && !['user','admin'].includes(body.role)))
        return reply(400,{error:'Invalid settings.'});
      return reply(200,{member:await rpc('manage_member',{p_admin:user.id,p_user:body.userId,p_active:body.active ?? null,p_role:body.role ?? null})});
    }
    if(req.method==='POST' && req.url==='/api/accounts'){
      if(user.role!=='admin') return reply(403,{error:'Administrator access required.'});
      const body=await json(req);
      if(!await rateLimit('invite:'+user.id)) return reply(429,{error:'Try again later.'});
      try {return reply(200,await issueAccess(body.userId,body.email,'invite'));}
      catch(e){return reply(e.status ?? 502,{error:e.status===409?'Check the member and their assigned email.':'Could not create an invitation code. Check the work email address.'});}
    }
    const route=new URL(req.url,origin);
    if(req.method==='POST' && route.pathname==='/api/files') return reply(200,{task:await uploadResult(req,user,route)});
    if(req.method==='GET' && /^\/api\/files\/[a-f0-9-]{36}$/.test(route.pathname)){
      const {attachment,response}=await downloadFile(user,route.pathname.split('/').pop());
      res.setHeader('Content-Type','application/octet-stream');
      res.setHeader('Content-Disposition',"attachment; filename*=UTF-8''"+encodeURIComponent(attachment.name));
      await pipeline(Readable.fromWeb(response.body),res);return;
    }
    if(req.method==='GET' && /^\/api\/history\/[0-9]+$/.test(route.pathname))
      return reply(200,{events:await rpc('task_api',{p_user:user.id,p_action:'history',p_data:{number:route.pathname.split('/').pop()}})});
    if(req.method==='GET' && route.pathname==='/api/tasks') {
      const data=Object.fromEntries(route.searchParams);
      return reply(200,{tasks:await rpc('task_api',{p_user:user.id,p_action:'list',p_data:data})});
    }
    if(req.method==='GET' && /^\/api\/tasks\/[1-9][0-9]*$/.test(route.pathname)) {
      return reply(200,{task:await rpc('task_api',{p_user:user.id,p_action:'task',p_data:{number:route.pathname.split('/').pop()}})});
    }
    if(req.method==='POST' && route.pathname==='/api/tasks') {
      const body=await json(req);
      if(!['create','edit','begin','result','approve','return','cancel','restore','delete','materials','complete'].includes(body.action) ||
        !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body.requestId ?? '') ||
        !body.data || typeof body.data!=='object' || Array.isArray(body.data)) return reply(400,{error:'Invalid request.'});
      const task=await rpc('task_api',{p_user:user.id,p_action:body.action,p_data:body.data,p_request:body.requestId});
      return reply(200,{task});
    }
    if(req.method==='POST' && route.pathname==='/api/projects'){
      const body=await json(req);
      if(!['project_create','project_archive','project_admins','project_delete','project_members','project_visibility'].includes(body.action) || !body.data || typeof body.data!=='object')
        return reply(400,{error:'Invalid request.'});
      if(body.action==='project_delete'){
        const id=body.data.id;
        if(!Number.isSafeInteger(id) || id<1)return reply(400,{error:'Invalid project.'});
        const outcome=await rpc('delete_empty_project',{p_user:user.id,p_project:id});
        if(outcome==='has_tasks')return reply(422,{error:'Could not delete the project and its tasks.'});
        return reply(200,{ok:true});
      }
      return reply(200,{project:await rpc('team_command_user',{p_user:user.id,p_action:body.action,p_data:body.data})});
    }
    if(req.method==='GET' && route.pathname==='/api/projects') return reply(200,{projects:await rpc('team_command_user',{p_user:user.id,p_action:'projects'})});
    if(req.method==='GET' && route.pathname==='/api/members') return reply(200,{members:await rpc('team_command_user',{p_user:user.id,p_action:'members'})});
    if(req.method==='GET' && req.url==='/api/me') return reply(200,{user});
    if(req.method==='POST' && req.url==='/api/logout'){
      const token=(req.headers.cookie ?? '').split(';').map(x=>x.trim()).find(x=>x.startsWith('session='))?.slice(8);
      if(token) await database('/rest/v1/web_sessions?token_hash=eq.'+hash(token),{method:'DELETE'});
      res.setHeader('Set-Cookie','session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'+(secure?'; Secure':''));
      return reply(200,{ok:true});
    }
    reply(404,{error:'Not found.'});
  }catch(error){console.error('API request failed',error.status ?? 500);reply(error.status ?? 500,{error:'Could not complete the request.'});}
});
server.listen(Number(process.env.PORT ?? 3000),process.env.HOST ?? '127.0.0.1',()=>console.log('API listening at '+origin));

void runStorageCleanup();

void runMemberCleanup();
