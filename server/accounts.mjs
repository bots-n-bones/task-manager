export async function auth(path,body,token=process.env.SUPABASE_SECRET_KEY,method='POST') {
  const response=await fetch(new URL('/auth/v1/'+path,process.env.SUPABASE_URL),{
    method,headers:{apikey:process.env.SUPABASE_SECRET_KEY,Authorization:'Bearer '+token,'content-type':'application/json'},
    body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
  const data=await response.json();
  if(!response.ok) throw Object.assign(new Error('Account operation failed'),{status:response.status>=500?502:422,authStatus:response.status});
  return data;
}
