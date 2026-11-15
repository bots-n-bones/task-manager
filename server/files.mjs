import {createHash} from 'node:crypto';
import {database,rpc} from './db.mjs';
const base=process.env.SUPABASE_URL;
const headers={apikey:process.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+process.env.SUPABASE_SECRET_KEY};
export async function uploadResult(request,user,route) {
  const number=route.searchParams.get('number'),version=route.searchParams.get('version'),id=route.searchParams.get('requestId');
  if(!/^[0-9]{1,18}$/.test(number ?? '') || !/^[0-9]{1,18}$/.test(version ?? '') || !/^[a-f0-9-]{36}$/.test(id ?? ''))
    throw Object.assign(new Error('Invalid upload request'),{status:400});
  const cached=await database('/rest/v1/web_requests?select=response&user_id=eq.'+user.id+'&request_id=eq.'+id);
  if(cached.length)return cached[0].response;
  // Check ownership before accepting the upload, then check again on commit.
  const task=await rpc('task_api',{p_user:user.id,p_action:'task',p_data:{number}});
  if(!task.assignees.some(x=>x.id===user.id) || task.status!=='in_progress')
    throw Object.assign(new Error('Upload denied'),{status:403});
  let size=0;const chunks=[];
  for await(const chunk of request){size+=chunk.length;if(size>10485760)throw Object.assign(new Error('File too large'),{status:413});chunks.push(chunk);}
  if(!size)throw Object.assign(new Error('Empty file'),{status:422});
  const bytes=Buffer.concat(chunks),digest=createHash('sha256').update(bytes).digest('hex');
  const path=user.id+'/'+id+'/'+digest;
  let name,caption;
  try{name=decodeURIComponent(request.headers['x-file-name'] ?? 'file');caption=decodeURIComponent(request.headers['x-caption'] ?? '');}
  catch{throw Object.assign(new Error('Invalid filename'),{status:400});}
  if(name.length>255 || caption.length>1000)throw Object.assign(new Error('Invalid file fields'),{status:422});
  const type=request.headers['content-type'] ?? 'application/octet-stream';
  await rpc('file_stage',{p_path:path});
  const stored=await fetch(base+'/storage/v1/object/task-results/'+path,{method:'POST',headers:{...headers,'content-type':type},body:bytes,signal:AbortSignal.timeout(45000)});
  if(!stored.ok && ![400,409].includes(stored.status))throw Object.assign(new Error('Storage failed'),{status:502});
  if(!stored.ok){const error=await stored.json();if(!['Duplicate','ResourceAlreadyExists','409'].includes(String(error.error ?? error.statusCode)))throw Object.assign(new Error('Storage failed'),{status:502});}
  return rpc('web_file_result',{p_user:user.id,p_request:id,p_number:number,p_version:version,p_text:caption,p_file:{name,mime_type:type,size,path}});
}
export async function downloadFile(user,id){
 const attachment=await rpc('attachment_access_user',{p_user:user.id,p_id:id});
 const response=await fetch(base+'/storage/v1/object/authenticated/task-results/'+attachment.storage_path,{headers,signal:AbortSignal.timeout(45000)});
 if(!response.ok)throw Object.assign(new Error('File unavailable'),{status:502});
 return {attachment,response};
}
