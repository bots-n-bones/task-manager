// Isolated UI fixture: no database, credentials, email or Telegram messages.
// Run: node scripts/checks/review-flow-preview.mjs
// Member: http://127.0.0.1:18731/  Admin: http://127.0.0.1:18731/?role=admin
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
const member={id:'10000000-0000-4000-8000-000000000001',name:'Alex',role:'user'};
const admin={id:'10000000-0000-4000-8000-000000000002',name:'Sam',role:'admin'};
const task={id:'20000000-0000-4000-8000-000000000001',number:1,title:'Prepare the launch report',
 description:'Sample task for the review workflow test.',due_date:'2099-01-01',status:'in_progress',version:1,
 author_id:member.id,project_id:1,project:'Review workflow demo',created_at:new Date().toISOString(),
 assignees:[member],admins:[admin],attachments:[],important:false,quick:false,result:null};
const reviews=[],events=[],previewMembers=[member,admin];
function details(){const latest=reviews[0];return {...task,result:task.status==='in_progress'?null:task.result,
 reviews,latest_review:latest?{...latest,needs_changes:latest.decision==='returned'&&task.status==='in_progress'}:null};}
createServer(async(req,res)=>{
 res.setHeader('Cache-Control','no-store');
 const url=new URL(req.url,'http://127.0.0.1:18731');
 const role=new URL(req.headers.referer||url.href).searchParams.get('role');
 const actor=role==='admin'?admin:member;
 const previewOptions=new URL(req.headers.referer||url.href).searchParams;
 const previewRoster=previewOptions.get('admins')==='two'?[...previewMembers,{id:'10000000-0000-4000-8000-000000000003',name:'Morgan',role:'admin'}]:previewMembers;
 const reply=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(value));};
 if(url.pathname==='/fixture-capabilities.js'){
   res.writeHead(200,{'Content-Type':'text/javascript'});return res.end(`
     Object.defineProperty(crypto,'randomUUID',{value:undefined});
     if(new URL(location.href).searchParams.get('compat')==='clipboard')Object.defineProperty(navigator,'clipboard',{configurable:true,get(){return undefined;}});
     Object.defineProperty(window,'localStorage',{get(){throw new Error('Storage blocked in preview');}});
     const originalMatchMedia=window.matchMedia.bind(window);
     window.matchMedia=query=>{const result=originalMatchMedia(query);result.addEventListener=undefined;return result;};
   `);
 }
 if(url.pathname==='/api/logout')return reply({error:'Session expired'},401);
 if(req.method==='POST'&&url.pathname==='/api/tasks'&&previewOptions.get('fault')){
   if(previewOptions.get('fault')==='html'){res.writeHead(502,{'Content-Type':'text/html'});return res.end('<html>Bad gateway</html>');}
   if(previewOptions.get('fault')==='expired')return reply({error:'Session expired'},401);
   if(previewOptions.get('fault')==='network')return req.socket.destroy();
 }
 if(url.pathname==='/api/files'&&req.method==='POST'){
   for await(const chunk of req){} // Discard synthetic test upload; never write files.
   if(!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(url.searchParams.get('requestId')))return reply({error:'Invalid request ID'},400);
   task.status='review';task.result=decodeURIComponent(req.headers['x-caption']||'File attached');task.version++;
   return reply({task:details()});
 }
 if(url.pathname==='/api/me')return role==='guest'?reply({error:'Sign-in required'},401):reply({user:actor});
 if(url.pathname==='/api/recover')return reply({ok:true});
 if(url.pathname==='/api/accounts')return req.method==='POST'?reply({code:'preview-code-not-a-real-invitation',expiresAt:new Date(Date.now()+86400000).toISOString()}):reply({members:previewRoster.map(m=>({...m,active:true,corporate_email:previewOptions.get('compat')==='clipboard'?'preview@bots-n-bones.com':undefined}))});
 if(url.pathname==='/api/access-mode')return reply({emailOnly:true});
 if(url.pathname==='/api/projects')return reply({projects:[{id:1,name:task.project,archived:false,admins:[admin.id]}]});
 if(url.pathname==='/api/members'){
   if(req.method==='POST'){
     let raw='';for await(const chunk of req)raw+=chunk;
     const {name}=JSON.parse(raw);if(!name?.trim())return reply({error:'Name required'},422);
     const created={id:crypto.randomUUID(),name:name.trim(),role:'user'};previewMembers.push(created);return reply({member:created});
   }
   return reply({members:previewRoster});
 }
 if(url.pathname==='/api/tasks/1')return reply({task:details()});
 if(url.pathname==='/api/history/1')return reply({events});
 if(url.pathname==='/api/tasks'&&req.method==='GET'){
   let visible=!(url.searchParams.get('mine')==='true'&&actor.id!==member.id);
   const view=url.searchParams.get('view');
   if(view==='active'&&['done','cancelled'].includes(task.status))visible=false;
   if(view==='archive'&&(!['done','cancelled'].includes(task.status)||actor.id!==member.id))visible=false;
   if(url.searchParams.has('status')&&url.searchParams.get('status')!==task.status)visible=false;
   return reply({tasks:visible?[details()]:[]});
 }
 if(url.pathname==='/api/tasks'&&req.method==='POST'){
   let raw='';for await(const chunk of req)raw+=chunk;
   const {action,data}=JSON.parse(raw);
   if(Number(data.version)!==task.version)return reply({error:'Version conflict'},409);
   const before={...task};
   if(action==='result'&&actor.id===member.id&&task.status==='in_progress'&&data.text?.trim()){
     task.result=data.text;task.status='review';
   }else if(['return','approve'].includes(action)&&actor.role==='admin'&&task.status==='review'){
     if(action==='return'&&!data.comment?.trim())return reply({error:'Feedback required'},422);
     reviews.unshift({id:crypto.randomUUID(),decision:action==='return'?'returned':'approved',
       comment:data.comment||null,reviewer_name:admin.name,created_at:new Date().toISOString(),result_version:task.version});
     task.status=action==='return'?'in_progress':'done';
   }else if(action==='cancel'&&actor.id===member.id){task.status='cancelled';}else return reply({error:'Action unavailable'},403);
   task.version++;events.push({id:events.length+1,event:'update',created_at:new Date().toISOString(),changes:{before,after:{...task}}});
   return reply({task:details()});
 }
 const file=url.pathname==='/'?'index.html':url.pathname.slice(1);
 if(!/^(index\.html|app\.js|browser\.mjs|style\.css|bnb-logo\.png|tokens\/[a-z-]+\.css)$/.test(file))return reply({error:'Not found'},404);
 try{
   const data=await readFile(new URL('../../web/'+file,import.meta.url));
   const mime=(file.endsWith('.js')||file.endsWith('.mjs'))?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.png')?'image/png':'text/html';
   res.writeHead(200,{'Content-Type':mime});res.end(file==='index.html'&&url.searchParams.has('compat')?data.toString().replace('<head>','<head><script src="/fixture-capabilities.js"></script>'):data);
 }catch{return reply({error:'Not found'},404);}
}).listen(18731,'127.0.0.1',()=>console.log('Isolated review workflow fixture: http://127.0.0.1:18731/'));
