const base=process.env.SUPABASE_URL;
const key=process.env.SUPABASE_SECRET_KEY;
export async function database(path,{method='GET',body,headers={}}={}) {
  const response=await fetch(new URL(path,base),{method,
    headers:{apikey:key,Authorization:'Bearer '+key,'content-type':'application/json',...headers},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
  if(!response.ok) {
    const error=await response.json().catch(()=>({}));
    const status={ '42501':403,'40001':409,'23514':422,'23502':422,'23505':409,'22023':400,'22P02':400,'22007':400,'22008':400 }[error.code] ?? 502;
    throw Object.assign(new Error('Database request failed'),{status});
  }
  if(response.status===204) return null;
  const text=await response.text();
  return text?JSON.parse(text):null;
}
export const rpc=(name,body)=>database('/rest/v1/rpc/'+name,{method:'POST',body});
