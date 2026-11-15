// Browser capabilities used by the UI, with safe fallbacks for restricted webviews.
export function newRequestId(provider=globalThis.crypto){
  if(typeof provider?.randomUUID==='function')return provider.randomUUID();
  if(typeof provider?.getRandomValues!=='function')throw new Error('This browser cannot create secure requests. Open the app in an up-to-date browser.');
  const bytes=new Uint8Array(16);provider.getRandomValues(bytes);
  bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
  const hex=Array.from(bytes,value=>value.toString(16).padStart(2,'0')).join('');
  return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
}
export function watchTheme(query,callback){
  if(typeof query?.addEventListener==='function')query.addEventListener('change',callback);
  else if(typeof query?.addListener==='function')query.addListener(callback);
}
export async function requestJson(url,options,fetcher=globalThis.fetch){
  let response;
  try{response=await fetcher(url,options);}
  catch{throw new Error('Could not connect. Check your connection and try again.');}
  let result;
  try{result=await response.json();}
  catch{throw Object.assign(new Error('The service is temporarily unavailable. Try again shortly.'),{status:response.status});}
  return {response,result};
}
