import assert from 'node:assert/strict';
import {database,rpc} from '/app/server/db.mjs';
import {issueAccess,finishAccess} from '/app/server/email-access.mjs';
const base='https://tasks.molotilka.site';
const users=[];
const files=[];
const stamp=Date.now();
const [root]=await database('/rest/v1/users?telegram_id=eq.1287414278');
async function request(path,cookie,body,method='POST'){
 return fetch(base+'/api/'+path,body===undefined?{headers:{cookie}}:{
 method,headers:{cookie,origin:base,'content-type':'application/json'},body:JSON.stringify(body)});
}
async function provision(suffix,admin=false){
 const user=await rpc('create_member',{p_admin:root.id,p_name:'HTTP verification '+suffix});
 users.push(user);
 if(admin)await rpc('manage_member',{p_admin:root.id,p_user:user.id,p_role:'admin'});
 const email='qa.'+stamp+suffix+'@bots-n-bones.com';
 const {code}=await issueAccess(user.id,email,'invite');
 const password=crypto.randomUUID()+'-qa';
 await finishAccess({code,password});
 const [mapped]=await database('/rest/v1/users?id=eq.'+user.id);
 user.authId=mapped.auth_id;
 const response=await request('login','',{email,password});
 assert.equal(response.status,200,'password login');
 user.cookie=response.headers.get('set-cookie').split(';')[0];
 return user;
}
async function mutation(user,action,data,id=crypto.randomUUID()){
 return request('tasks',user.cookie,{action,data,requestId:id});
}
try{
 const owner=await provision('a'),outsider=await provision('b'),admin=await provision('c',true);
 const {projects}=await (await request('projects',owner.cookie)).json();
 const creationId=crypto.randomUUID();
 const create=await mutation(owner,'create',{title:'Disposable HTTP verification',project_id:projects.find(p=>!p.archived).id,due_date:'2026-11-30'},creationId);
 assert.equal(create.status,200);
 let {task}=await create.json();
 const replay=await mutation(owner,'create',{},creationId);
 assert.equal((await replay.json()).task.id,task.id);
 assert.equal((await request('tasks/'+task.number,outsider.cookie)).status,403);
 // Both writes use the same version. Exactly one may commit.
 const edits=await Promise.all(['Concurrent A','Concurrent B'].map(title=>mutation(owner,'edit',{number:task.number,version:task.version,title})));
 assert.deepEqual(edits.map(r=>r.status).sort(),[200,409]);
 ({task}=await (await request('tasks/'+task.number,owner.cookie)).json());
 const start=await mutation(owner,'begin',{number:task.number,version:task.version});
 ({task}=await start.json());
 assert.equal((await mutation(owner,'approve',{number:task.number,version:task.version})).status,403);
 const uploadId=crypto.randomUUID();
 const content='Production HTTP file verification '+stamp;
 const upload=await fetch(base+'/api/files?'+new URLSearchParams({number:task.number,version:task.version,requestId:uploadId}),{
 method:'POST',headers:{cookie:owner.cookie,origin:base,'content-type':'text/plain','x-file-name':'http-check.txt'},body:content});
 assert.equal(upload.status,200);
 ({task}=await (await request('tasks/'+task.number,owner.cookie)).json());
 assert.equal(task.status,'review');
 const attachment=task.attachments.find(f=>f.name==='http-check.txt');
 const [metadata]=await database('/rest/v1/task_attachments?id=eq.'+attachment.id);files.push(metadata.storage_path);
 assert.equal(await (await request('files/'+attachment.id,owner.cookie)).text(),content);
 assert.equal((await request('files/'+attachment.id,outsider.cookie)).status,403);
 assert.equal((await mutation(admin,'return',{number:task.number,version:task.version,comment:'Test correction'})).status,200);
 ({task}=await (await request('tasks/'+task.number,owner.cookie)).json());
 assert.equal(task.status,'in_progress');
 assert.equal((await mutation(owner,'result',{number:task.number,version:task.version,text:'Corrected'})).status,200);
 ({task}=await (await request('tasks/'+task.number,admin.cookie)).json());
 const approval=await mutation(admin,'approve',{number:task.number,version:task.version});
 assert.equal(approval.status,200);
 assert.equal((await approval.json()).task.status,'done');
 const history=await request('history/'+task.number,owner.cookie);
 assert.equal(history.status,200);
 console.log('Verified password login, idempotency, parallel edits, access, upload/download, return, approval and history');
}finally{
 for(const user of users)if(user.cookie)await request('logout',user.cookie,{});
 if(files.length)await fetch(process.env.SUPABASE_URL+'/storage/v1/object/task-results',{method:'DELETE',
 headers:{apikey:process.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+process.env.SUPABASE_SECRET_KEY,'content-type':'application/json'},body:JSON.stringify({prefixes:files})});
 console.log('CLEANUP '+JSON.stringify(users.map(({id,authId})=>({id,authId}))));
}
