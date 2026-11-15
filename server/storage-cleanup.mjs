import {setTimeout as delay} from 'node:timers/promises';
import {rpc} from './db.mjs';
export async function cleanupStorage() {
  const paths=await rpc('file_cleanup_claim',{});
  if(!paths.length)return 0;
  const response=await fetch(new URL('/storage/v1/object/task-results',process.env.SUPABASE_URL),{
    method:'DELETE',headers:{apikey:process.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+process.env.SUPABASE_SECRET_KEY,'content-type':'application/json'},
    body:JSON.stringify({prefixes:paths}),signal:AbortSignal.timeout(45000)
  });
  if(!response.ok)throw new Error('Storage cleanup HTTP '+response.status);
  await rpc('file_cleanup_done',{p_paths:paths});
  return paths.length;
}
export async function runStorageCleanup() {
  for(;;){
    try { const count=await cleanupStorage();if(count)console.log('Unlinked files removed:',count); }
    catch(error){console.error('Storage cleanup:',error.message);}
    await delay(300000);
  }
}
