import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';

const forwarded=[];
const user={id:randomUUID(),name:'Routing check',role:'admin',active:true};
const backend=createServer(async(req,res)=>{
 let body='';
 for await(const chunk of req)body+=chunk;
 const path=new URL(req.url,'http://localhost').pathname;
 let result=[];
 if(path==='/rest/v1/web_sessions')result=[{user_id:user.id}];
 if(path==='/rest/v1/users')result=[user];
 if(['/rest/v1/rpc/task_api','/rest/v1/rpc/team_command_user'].includes(path)){
   forwarded.push(JSON.parse(body));result={ok:true};
 }
 res.setHeader('content-type','application/json');
 res.end(JSON.stringify(result));
});
await new Promise(resolve=>backend.listen(0,'127.0.0.1',resolve));
const socket=createServer();
await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));
const port=socket.address().port;
await new Promise(resolve=>socket.close(resolve));
const origin='http://127.0.0.1:'+port;
const child=spawn(process.execPath,['server/main.mjs'],{
 env:{...process.env,HOST:'127.0.0.1',PORT:String(port),APP_ORIGIN:origin,
 SUPABASE_URL:'http://127.0.0.1:'+backend.address().port,SUPABASE_SECRET_KEY:'test'},
 stdio:'ignore'
});
try{
 for(let attempt=0;attempt<60;attempt++){
   if(await fetch(origin+'/health').then(response=>response.ok).catch(()=>false))break;
   await new Promise(resolve=>setTimeout(resolve,50));
 }
 const request=(path,action,data)=>fetch(origin+'/api/'+path,{
   method:'POST',headers:{origin,cookie:'session='+'a'.repeat(43),'content-type':'application/json'},
   body:JSON.stringify({action,data,requestId:randomUUID()})
 });
 for(const [path,action,data] of [
   ['tasks','materials',{number:1,version:1,links:[{title:'Calendar Work',url:'https://calendar.google.com/'}]}],
   ['tasks','complete',{number:1,version:1}],
   ['projects','project_members',{id:1,members:[user.id]}],
   ['projects','project_visibility',{id:1,visibility:'personal'}]
 ]){
   const response=await request(path,action,data);
   assert.equal(response.status,200,action+' reaches database authorization');
   assert.equal(forwarded.at(-1).p_action,action);
   assert.equal(forwarded.at(-1).p_user,user.id);
   assert.deepEqual(forwarded.at(-1).p_data,data);
 }
 const count=forwarded.length;
 assert.equal((await request('tasks','unsupported',{})).status,400);
 assert.equal((await request('projects','unsupported',{})).status,400);
 assert.equal(forwarded.length,count);
 console.log('Working links, recurring completion and project access changes reach database authorization; unknown actions rejected');
}finally{
 child.kill();
 await new Promise(resolve=>child.once('exit',resolve));
 await new Promise(resolve=>backend.close(resolve));
}
