import {database} from '../server/db.mjs';
import {setTimeout as delay} from 'node:timers/promises';

export function deliveryMessages(delivery) {
  const heading=delivery.kind==='deadline'?'Tasks due today':'Overdue tasks';
  const messages=[];
  let text=heading;
  for (const task of delivery.tasks) {
    const line='\n'+task.title+' · '+task.due_date.split('-').reverse().join('.');
    if (text.length+line.length>3500) { messages.push(text); text=heading+' (continued)'; }
    text+=line;
  }
  messages.push(text);
  return messages;
}

export async function deliverNotification(delivery,telegram) {
  try {
    for (const text of deliveryMessages(delivery)) {
      await telegram('sendMessage',{
        chat_id:delivery.telegram_id,text,
        reply_markup:{inline_keyboard:[[{text:delivery.kind==='deadline'?'Due today':'Overdue',
          callback_data:delivery.kind==='deadline'?'today:0':'overdue:0'}]]}
      });
    }
    return {p_status:'sent',p_error:null,p_delay:60};
  } catch(failure) {
    return {
      p_status:failure.code===403?'unavailable':'retry',
      p_error:failure.code?'Telegram HTTP '+failure.code:'Telegram request failed',
      p_delay:Math.max(failure.retry ?? 0,Math.min(3600,30*2**delivery.attempts))
    };
  }
}

export async function runNotifications({telegram,allowed,url,key}) {
  async function rpc(name,params) {
    const response=await fetch(new URL('/rest/v1/rpc/'+name,url),{
      method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'content-type':'application/json'},
      body:JSON.stringify(params),signal:AbortSignal.timeout(15000)
    });
    if (!response.ok) throw new Error('Notification database HTTP '+response.status);
    return response.status===204?null:response.json();
  }

  for (;;) {
    try {
      const profiles=await database('/rest/v1/users?select=telegram_id&active=eq.true&telegram_id=not.is.null');
      const ids=profiles.map(p=>p.telegram_id);
      await rpc('notification_queue',{p_allowed:ids});
      // Bound each batch so new work and daily rollover are checked regularly.
      for (let count=0;count<20;count++) {
        const delivery=await rpc('notification_claim',{p_allowed:ids});
        if (!delivery) break;
        const outcome=await deliverNotification(delivery,telegram);
        await rpc('notification_finish',{p_id:delivery.id,p_token:delivery.lease_token,...outcome});
      }
    } catch (error) {
      console.error('Notification worker:',error.message);
    }
    await delay(60000);
  }
}
