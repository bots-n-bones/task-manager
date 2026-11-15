import {database,rpc} from './db.mjs';
import {auth} from './accounts.mjs';
import {setTimeout as delay} from 'node:timers/promises';
let cleaning=false;
export async function cleanupDeletedMembers(userId,db=database,authRequest=auth){
  const jobs=await db('/rest/v1/member_deletions?select=user_id,auth_id&auth_deleted_at=is.null'+(userId?'&user_id=eq.'+userId:'')+'&limit=10');
  for(const job of jobs){
    if(job.auth_id){
      try{await authRequest('admin/users/'+job.auth_id,undefined,undefined,'DELETE');}
      catch(error){if(error.authStatus!==404)throw error;}
    }
    await db('/rest/v1/member_deletions?user_id=eq.'+job.user_id,{method:'PATCH',body:{auth_deleted_at:new Date().toISOString()}});
  }
  return jobs.length;
}
export async function deleteMember(admin,userId,successor){
  const result=await rpc('delete_member',{p_admin:admin,p_user:userId,p_successor:successor});
  try{await cleanupDeletedMembers(userId);}
  catch{console.error('Deleted member login cleanup pending');}
  return result;
}
export async function runMemberCleanup(){
  for(;;){
    if(!cleaning){
      cleaning=true;
      try{await cleanupDeletedMembers();}catch{console.error('Member login cleanup will retry');}
      finally{cleaning=false;}
    }
    await delay(60000);
  }
}
