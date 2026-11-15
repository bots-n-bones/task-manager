const maxSize=10*1024*1024;

export async function handleFile({msg,actor,update,telegram,url,key}) {
  const headers={apikey:key,Authorization:'Bearer '+key};
  async function rpc(name,params) {
    const res=await fetch(new URL('/rest/v1/rpc/'+name,url),{method:'POST',
      headers:{...headers,'content-type':'application/json'},body:JSON.stringify(params),signal:AbortSignal.timeout(15000)});
    if (!res.ok) throw Object.assign(new Error('File database HTTP '+res.status),{status:res.status});
    return res.json();
  }
  const cached=await fetch(new URL('/rest/v1/processed_updates?select=response&update_id=eq.'+update.update_id,url),
    {headers,signal:AbortSignal.timeout(15000)});
  if (!cached.ok) throw new Error('File replay lookup HTTP '+cached.status);
  const rows=await cached.json();
  if(rows.length) return rows[0].response;
  if(!await rpc('attachment_access',{p_actor:actor.id})) return {message:'Open the task and press Submit result.'};
  const file=msg.document ?? msg.photo?.at(-1);
  if (!file || !file.file_size || file.file_size>maxSize) return {message:'Send a document or photo up to 10 MB.'};
  if ((msg.caption ?? '').length>1000) return {message:'The caption must not exceed 1,000 characters.'};
  const info=await telegram('getFile',{file_id:file.file_id});
  if (!info.file_path || info.file_size>maxSize) return {message:'The file exceeds the 10 MB limit.'};
  const remote=await fetch('https://api.telegram.org/file/bot'+process.env.TELEGRAM_BOT_TOKEN+'/'+info.file_path,
    {signal:AbortSignal.timeout(45000)});
  if (!remote.ok) throw new Error('Telegram download HTTP '+remote.status);
  const reader=remote.body.getReader();
  const chunks=[];
  let size=0;
  for (;;) {
    const {value,done}=await reader.read();
    if(done) break;
    size+=value.length;
    if(size>maxSize) {await reader.cancel();return {message:'The file exceeds the 10 MB limit.'};}
    chunks.push(value);
  }
  if(!size) return {message:'The file is empty.'};
  const bytes=Buffer.concat(chunks);
  const path=actor.id+'/'+update.update_id;
  const mime=msg.document?.mime_type ?? 'image/jpeg';
  try { await rpc('file_stage',{p_path:path}); }
  catch(error){
    if(error.status===409)return {message:'Upload timed out. Send the file again.'};
    throw error;
  }
  const stored=await fetch(new URL('/storage/v1/object/task-results/'+path,url),{
    method:'POST',headers:{...headers,'content-type':mime,'x-upsert':'true'},body:bytes,signal:AbortSignal.timeout(45000)
  });
  if(!stored.ok) throw new Error('Storage upload HTTP '+stored.status);
  try { return await rpc('attachment_result',{p_actor:actor.id,p_update:update.update_id,p_name:actor.first_name || String(actor.id),
    p_caption:msg.caption ?? '',p_file:{name:(msg.document?.file_name ?? 'photo.jpg').slice(0,255),mime_type:mime,
      size,path,file_id:file.file_id,kind:msg.document?'document':'photo'}});
  }catch(error){
    if([403,409,422].includes(error.status))return {message:'The task or permissions have changed. Reopen the task and resubmit your result.'};
    throw error;
  }
}

export async function getAttachment({actor,id,url,key}) {
  const res=await fetch(new URL('/rest/v1/rpc/attachment_access',url),{method:'POST',
    headers:{apikey:key,Authorization:'Bearer '+key,'content-type':'application/json'},
    body:JSON.stringify({p_actor:actor.id,p_id:id}),signal:AbortSignal.timeout(15000)});
  if(res.status===403) return null;
  if(!res.ok) throw new Error('Attachment access HTTP '+res.status);
  return res.json();
}
