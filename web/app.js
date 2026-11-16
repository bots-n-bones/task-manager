import {newRequestId,watchTheme,requestJson} from './browser.mjs';
const app=document.querySelector('#app'),dialog=document.querySelector('#dialog'),content=document.querySelector('#dialog-content');
const statuses={new:'New',in_progress:'In progress',recurring:'Recurring',review:'In review',done:'Done',cancelled:'Cancelled'};
const moscowDate = new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Moscow',dateStyle:'short'});
const displayDate = value => value.slice(0,10).split('-').reverse().join('.');
const importanceOptions = [['true','Important'],['false','Normal']];
const durationOptions = [['quick','Quick'],['renewable','Recurring']];
const themeOptions = [['auto','Auto'],['light','Light'],['night','Night']];
const themeKey = 'task-manager-theme';
let theme = 'auto';
try {
 const saved = localStorage.getItem(themeKey);
 if(themeOptions.some(([value])=>value===saved))theme=saved;
} catch {
 // The theme still works in webviews that block local storage.
}
let dialogBack=null;
let user,projects=[],members=[],page=0,scope='mine',filters={},activeProject=null,projectVisibility='shared';
function el(tag,text,cls){const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;}
function topbar(){
 const bar=el('header',undefined,'topbar');
 const logo=el('img',undefined,'brand-logo');
 logo.src='/bnb-logo.png';logo.alt='Bots and Bones';
 bar.append(logo,el('span','Task Manager','app-name'));
 const picker=el('div',undefined,'theme-picker');
 const themeSelect=select(picker,'theme','Theme',themeOptions,theme);
 themeSelect.onchange=()=>{
  theme=themeSelect.value;
  try { localStorage.setItem(themeKey,theme); } catch {}
  syncTheme();
 };
 bar.append(picker);
 return bar;
}
function isOverdue(t){
 const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Moscow'}).format(new Date());
 return !['done','cancelled'].includes(t.status) && t.due_date<today;
}
function needsChanges(task){return task.latest_review?.needs_changes===true;}
function reviewDate(value){return new Date(value).toLocaleString('en-GB',{timeZone:'Europe/Moscow'});}
function reviewTag(){return el('span','Changes requested','status review-tag');}
function feedbackPanel(task){
 const review=task.latest_review;
 if(review?.decision!=='returned' || !['in_progress','recurring','review'].includes(task.status))return null;
 if(['in_progress','recurring'].includes(task.status)&&!needsChanges(task))return null;
 const panel=el('section',undefined,'review-feedback');panel.setAttribute('aria-label','Review feedback');
 panel.append(el('h3',needsChanges(task)?'Changes requested':'Previous feedback'),
   el('p',review.reviewer_name+' · '+reviewDate(review.created_at),'muted'),el('p',review.comment,'detail'));
 if(needsChanges(task))panel.append(el('p','Update your result and submit it for review again.','muted'));
 return panel;
}
function overdueTag(){return el('span','Overdue','status overdue-tag');}
function statusTag(status){
 const tag=el('span',statuses[status],'status');
 tag.dataset.status=status;
 return tag;
}
let noticeTimer;
function notice(text){
 if(dialog.open){
   let n=dialog.querySelector('#dialog-notice');
   if(!n){n=el('p',undefined,'form-notice');n.id='dialog-notice';n.setAttribute('role','status');n.setAttribute('aria-live','polite');document.querySelector('#dialog-title').after(n);}
   n.textContent=text;n.scrollIntoView({block:'nearest'});return;
 }
 const n=document.querySelector('#notice');n.textContent=text;n.classList.add('show');
 clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>n.classList.remove('show'),7000);
}
async function api(path,body,method='POST'){
 const {response,result}=await requestJson('/api/'+path,body===undefined?{}:{method,headers:{'content-type':'application/json'},body:JSON.stringify(body)});
 if(path==='setup' && [400,422].includes(response.status))throw new Error('The code or link is invalid. Request a new one.');
 if(!response.ok)throw Object.assign(new Error(response.status===401&&path!=='login'?'Your session has expired. Reload this page to sign in again.':response.status===409&&path==='tasks'?'The task has changed. Refresh its details.':result?.error || 'Could not complete the request. Try again.'),{status:response.status});
 return result;
}
function button(text,fn,cls){const b=el('button',text,cls);b.type='button';b.onclick=async()=>{b.disabled=true;try{await fn();}catch(e){notice(e.message);}finally{b.disabled=false;}};return b;}
function field(form,name,label,type='text',value=''){const l=el('label',label),input=el(type==='textarea'?'textarea':'input');input.name=name;if(type!=='textarea')input.type=type;input.value=value ?? '';l.append(input);form.append(l);return input;}
function select(form,name,label,options,value=''){
 const l=el('label',label),control=el('span',undefined,'select-control'),input=el('select');
 input.name=name;
 for(const [v,text] of options){const o=el('option',text);o.value=v;input.append(o);}
 input.value=value;
 const arrow=document.createElementNS('http://www.w3.org/2000/svg','svg');
 arrow.setAttribute('viewBox','0 0 16 16');arrow.setAttribute('aria-hidden','true');arrow.setAttribute('focusable','false');
 const path=document.createElementNS('http://www.w3.org/2000/svg','path');
 path.setAttribute('d','M4 6l4 4 4-4');path.setAttribute('fill','none');path.setAttribute('stroke','currentColor');
 path.setAttribute('stroke-width','1.5');path.setAttribute('stroke-linecap','round');path.setAttribute('stroke-linejoin','round');
 arrow.append(path);control.append(input,arrow);l.append(control);form.append(l);return input;
}
function modal(title,back=null){
 dialogBack=back;
 const heading=el('h3',title);
 heading.id='dialog-title';
 content.replaceChildren(...(back?[button('← Back',back,'quiet')]:[]),heading);
 if(!dialog.open)dialog.showModal();
}
async function closeDialog(){
 try { if(dialogBack)await dialogBack();else dialog.close(); } catch(e){notice(e.message);}
}
document.querySelector('#close-dialog').onclick=closeDialog;
dialog.addEventListener('cancel',event=>{if(dialogBack){event.preventDefault();void closeDialog();}});
dialog.addEventListener('close',()=>{dialogBack=null;});
async function login(){
 app.replaceChildren();const box=el('section',undefined,'login');box.append(el('h2','Team'),el('p','Sign in to view your tasks.','muted'));
 const form=el('form');field(form,'email','Work email','email').required=true;field(form,'password','Password','password').required=true;
 const submit=el('button','Sign in','primary');form.append(submit);
 form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{await api('login',Object.fromEntries(new FormData(form)));await start();}catch(e){notice(e.message);}finally{submit.disabled=false;}};
 box.append(form,button('I have an invitation code',()=>setup()),button('Forgot password?',()=>recoverPassword(form.elements.email.value),'quiet'));app.append(topbar(),box);
}
function recoverPassword(address=''){
 modal('Reset password');
 const form=el('form'),email=field(form,'email','Work email','email',address),error=el('p');
 email.required=true;email.maxLength=254;email.autocomplete='email';error.setAttribute('role','alert');
 const submit=el('button','Send reset link','primary');
 form.append(error,submit);content.append(form);
 form.onsubmit=async event=>{
   event.preventDefault();if(submit.disabled)return;submit.disabled=true;error.textContent='';
   try{await api('recover',{email:email.value.trim()});dialog.close();notice('If your account is active, you will receive an email.');}
   catch(e){error.textContent=e.message;}finally{submit.disabled=false;}
 };
 email.focus();
}
function setup(code){
 modal('Set password');const form=el('form');
 const token=code?null:field(form,'code','Invitation code');
 if(token){token.required=true;token.autocapitalize='none';token.spellcheck=false;}
 const password=field(form,'password','New password, at least 12 characters','password');password.minLength=12;password.required=true;
 const submit=el('button','Save password','primary');form.append(submit);
 form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{await api('setup',{code:code ?? token.value.trim(),password:password.value});dialog.close();notice('Password saved. You can now sign in.');}catch(e){notice(e.message);}finally{submit.disabled=false;}};
 content.append(form);
}
async function start(){
 ({user}=await api('me'));
 [projects,members]=await Promise.all([api('projects').then(x=>x.projects),api('members').then(x=>x.members)]);
 const shell=el('div',undefined,'shell'),aside=el('aside'),navigation=el('nav');
 navigation.setAttribute('aria-label','Team navigation');
 aside.append(el('h1','Team'),navigation);
 for(const [key,label] of [['mine','My tasks'],['today','Due today'],['overdue','Overdue'],['projects','Projects'],...(user.role==='admin'?[['all','All tasks']]:[]),['archive','Archive'],...(user.role==='admin'?[['cancelled','Cancelled']]:[]),...(user.role==='admin'?[['accounts','Members']]:[])]){
  const b=button(label,async()=>{scope=key;activeProject=null;page=0;if(key==='archive')filters={};if(['today','overdue'].includes(key))delete filters.deadline;await screen();});b.dataset.scope=key;navigation.append(b);
 }
 const telegramLink=el('a','Open in Telegram');telegramLink.href='https://t.me/bnb_tasks_manager_bot?start=web';telegramLink.target='_self';const bottom=el('div',undefined,'sidebar-bottom');bottom.append(button('Link Telegram',async()=>{const {code}=await api('link-code',{});modal('Link Telegram');content.append(el('p','Send this command to the bot within 15 minutes.'),el('code','/link '+code));}),el('footer',user.name));aside.append(telegramLink,bottom);shell.append(aside,el('main'));app.replaceChildren(topbar(),shell);await screen();
}
async function screen(){
 for(const b of document.querySelectorAll('[data-scope]')){
  const active=b.dataset.scope===(scope==='project'?'projects':scope);
  b.classList.toggle('active',active);
  if(active)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');
 }
 const main=document.querySelector('main');main.replaceChildren();
 if(scope==='accounts')return accounts(main);
 if(scope==='projects')return projectScreen(main);
 const header=el('header');
 if(activeProject)header.append(button('← Projects',async()=>{scope='projects';activeProject=null;page=0;await screen();},'breadcrumb quiet'));
 header.append(el('h2',activeProject?.name ?? ({mine:'My tasks',today:'Due today',overdue:'Overdue',all:'All tasks',cancelled:'Cancelled tasks',archive:'Task archive'})[scope]));
 if(!['cancelled','archive'].includes(scope)&&!activeProject?.archived)header.append(button('Create task',()=>edit(null,activeProject?.id ?? filters.project_id),'primary'));
 main.append(header);
 const bar=el('div',undefined,'filters');
 const projectOptions=activeProject?[]:[['project_id','Project',projects.map(p=>[String(p.id),p.name])]];
 const activeOnly=!['all','cancelled','archive'].includes(scope);
 if(activeOnly && ['done','cancelled'].includes(filters.status))delete filters.status;
 if(scope==='archive' && !['done','cancelled'].includes(filters.status))delete filters.status;
 const statusOptions=scope==='cancelled'?[]:[['status','Status',Object.entries(statuses).filter(([key])=>scope==='archive'?['done','cancelled'].includes(key):!activeOnly||!['done','cancelled'].includes(key))]];
 const teamList=user.role==='admin'&&(['all','cancelled'].includes(scope)||activeProject);
 for(const [key,label,opts] of [...projectOptions,...statusOptions,['important','Priority',importanceOptions],['duration','Duration',durationOptions],...(teamList?[['member','Assignee',members.map(m=>[m.id,m.name])]]:[])]){
  const input=select(bar,key,label,[['','All'],...opts],filters[key] ?? '');
  input.onchange=()=>{filters[key]=input.value;page=0;screen().catch(e=>notice(e.message));};
 }
 if(['mine','all','project','cancelled','archive'].includes(scope)){
   const dateFilter=el('div',undefined,'date-filter');
   const deadline=field(dateFilter,'deadline','Due date','date',filters.deadline ?? '');
   deadline.onchange=()=>{filters.deadline=deadline.value;page=0;screen().catch(e=>notice(e.message));};
   if(filters.deadline)dateFilter.append(button('Clear date',async()=>{
     delete filters.deadline;page=0;await screen();
   },'quiet'));
   bar.append(dateFilter);
 }
 main.append(bar);
 const params=new URLSearchParams({page,view:activeOnly?'active':scope,...(teamList?{}:{mine:true}),...(['today','overdue'].includes(scope)?{deadline:scope}:{})});
 for(const [key,value] of Object.entries(filters)){
   if(!value)continue;
   if(key==='duration')params.set(value,'true');
   else params.set(key,value);
 }
 if(activeProject)params.set('project_id',activeProject.id);
 if(scope==='cancelled')params.set('status','cancelled');
 if(scope==='archive')params.set('mine','true');
 const {tasks}=await api('tasks?'+params);
 if(!bar.isConnected)return;
 if(!tasks.length&&page){page--;return screen();}
 const list=el('div',undefined,'list');
 for(const t of tasks.slice(0,20)){
   const row=button('',()=>card(t.number),'task');
   const text=el('span');
   const meta=[t.project,'due '+displayDate(t.due_date)];
   if(t.important)meta.push('Important');
   if(t.renewable)meta.push('Recurring');
   else if(t.quick)meta.push('Quick');
   if(['all','cancelled'].includes(scope)&&t.assignee_names?.length)meta.push(t.assignee_names.join(', '));
   text.append(el('strong',t.title),el('small',meta.join(' · ')));
   if(needsChanges(t))text.append(reviewTag());
   if(isOverdue(t)){row.classList.add('overdue-task');text.append(overdueTag());}
   row.append(text,statusTag(t.status));
   list.append(row);
 }
 if(!tasks.length)list.append(el('div','No tasks match these filters.','empty'));main.append(list);
 const nav=el('div',undefined,'pager');if(page)nav.append(button('← Back',async()=>{page--;await screen();}));if(tasks.length>20)nav.append(button('Next →',async()=>{page++;await screen();}));nav.append(button('Refresh',screen),button('Sign out',async()=>{try{await api('logout',{});}catch(e){if(e.status!==401)throw e;}await login();}));main.append(nav);
}
async function mutate(action,t,data={},requestId=newRequestId()){const result=await api('tasks',{action,requestId,data:{number:t.number,version:t.version,...data}});return result.task;}
async function card(number){
 const {task:t}=await api('tasks/'+number);modal('Task',()=>dialog.close());
 content.append(el('h3',t.title),statusTag(t.status),...(isOverdue(t)?[overdueTag()]:[]));
 const feedback=feedbackPanel(t);if(feedback)content.append(feedback);
 if(t.status==='review')content.append(el('p',t.latest_review?.decision==='returned'?'Updated result submitted. Awaiting review.':'Waiting for an administrator to review your result.','muted'));
 content.append(el('p',t.description || 'No description provided.','detail'),
 el('p','Project · '+t.project),el('p','Due · '+displayDate(t.due_date)),el('p','Created · '+moscowDate.format(new Date(t.created_at))),
 el('p','Assignees · '+t.assignees.map(m=>m.name).join(', ')),el('p','Owners · '+t.admins.map(m=>m.name).join(', ')));
 content.append(el('p',[t.important?'Important':'Normal',t.renewable?'Recurring':t.quick?'Quick':''].filter(Boolean).join(' · ')));
 if(t.renewable)content.append(el('p','Keep working materials here as you update this task. An administrator can finish it when the work is complete.','muted'));
 content.append(el('h3','Working materials'));
 for(const material of t.working_links ?? []){
   const url=new URL(material.url);
   if(!['https:','http:'].includes(url.protocol))continue;
   const link=el('a',material.title);link.href=url.href;link.target='_self';
   const row=el('p');row.append(link);content.append(row);
 }
 if(!t.working_links?.length)content.append(el('p','No working links yet.','muted'));
 if(!['done','cancelled'].includes(t.status))content.append(button('Edit working links',()=>editMaterials(t)));
 if(t.result)content.append(el('div',undefined,'divider'),el('h3','Result'),el('p',t.result,'detail'));
 for(const file of t.attachments ?? []){const link=el('a','Download '+file.name);link.href='/api/files/'+file.id;const row=el('p');row.append(link);content.append(row);}
 const actions=el('div',undefined,'actions');
 actions.append(button('History',async()=>{
   const [{events},{task:current}]=await Promise.all([api('history/'+t.number),api('tasks/'+t.number)]);modal('Task history',()=>card(number));
   if(current.reviews?.length){
     content.append(el('h3','Review feedback'));
     for(const review of current.reviews){
       const item=el('section',undefined,'review-feedback');
       item.append(el('strong',review.decision==='returned'?'Changes requested':'Approved'),el('p',review.reviewer_name+' · '+reviewDate(review.created_at),'muted'));
       if(review.comment)item.append(el('p',review.comment,'detail'));
       content.append(item);
     }
     content.append(el('h3','Task changes'));
   }
   const names={insert:'Created',update:'Updated',attachment:'Attachment',team_edit:'Team or fields updated'};
   for(const event of events){
     const item=el('section',undefined,'account');
     item.append(el('strong',names[event.event] ?? event.event),el('p',new Date(event.created_at).toLocaleString('en-GB',{timeZone:'Europe/Moscow'}),'muted'));
     if(event.changes.name)item.append(el('p',event.changes.name));
     const before=event.changes.before,after=event.changes.after;
     if(before && after)for(const [key,label]of [['title','Title'],['due_date','Due date'],['status','Status'],['result','Result']]){
       if(before[key]!==after[key])item.append(el('p',label+' · '+(key==='status'?(statuses[after[key]] ?? after[key]):(after[key] ?? ''))));
     }
     content.append(item);
   }
 }));const assignee=t.assignees.some(m=>m.id===user.id);
 if(t.status==='recurring' && user.role==='admin')actions.append(button('Finish recurring task',()=>{
   modal('Finish recurring task?',()=>card(number));
   content.append(el('p','This will mark the task as Done. Working links remain available in its details.'),
     button('Mark as done',async()=>{await mutate('complete',t);await card(number);await screen();},'primary'));
 }));
 if(t.status==='new' && assignee)actions.append(button('Start work',async()=>{await mutate('begin',t);await card(number);await screen();},'primary'));
 if(['in_progress','recurring'].includes(t.status) && assignee)actions.append(button(needsChanges(t)?'Resubmit for review':'Submit result',()=>textAction(needsChanges(t)?'Resubmit for review':'Result','result',t,'text'),'primary'));
 if(t.status==='review' && user.role==='admin')actions.append(button(t.renewable?'Approve update':'Approve',async()=>{await mutate('approve',t);await card(number);await screen();},'primary'),button('Request changes',()=>textAction('Request changes','return',t,'comment')));
 if(!['done','cancelled'].includes(t.status) && (user.role==='admin'||t.author_id===user.id)){
  actions.append(button('Change due date',()=>editDeadline(t)),button('Edit',()=>edit(t)),button('Cancel task',()=>confirmTaskCancellation(t)));
 }
 if(t.status==='cancelled'){
  if(user.role==='admin'||t.author_id===user.id)actions.append(button('Restore',async()=>{
    await mutate('restore',t);await card(number);await screen();notice('Task restored.');
  },'primary'));
  if(user.role==='admin')actions.append(button('Delete task',()=>confirmTaskDeletion(t),'danger'));
 }content.append(actions);
}
function editMaterials(t){
 modal('Working materials',()=>card(t.number));
 const form=el('form'),rows=el('div'),items=[];
 const addRow=(material={})=>{
   if(items.length>=20){notice('You can pin up to 20 links.');return;}
   const row=el('fieldset'),title=field(row,'title','Name','text',material.title ?? ''),url=field(row,'url','Link','url',material.url ?? '');
   title.required=true;title.maxLength=120;url.required=true;url.maxLength=2048;
   const item={row,title,url};items.push(item);
   row.append(button('Remove link',()=>{items.splice(items.indexOf(item),1);row.remove();},'quiet'));
   rows.append(row);
 };
 for(const link of t.working_links ?? [])addRow(link);
 if(!items.length)addRow();
 const submit=el('button','Save links','primary');
 form.append(rows,button('Add link',()=>addRow()),submit);
 form.onsubmit=async event=>{
   event.preventDefault();submit.disabled=true;
   try{
     const links=items.map(({title,url})=>{
       const address=new URL(url.value.trim());
       if(!['https:','http:'].includes(address.protocol))throw new Error('Use an http or https link.');
       return {title:title.value.trim(),url:address.href};
     });
     await mutate('materials',t,{links});
     await card(t.number);await screen();
   }catch(error){notice(error.message);submit.disabled=false;}
 };
 content.append(form);
}
function editDeadline(t){
 modal('Change due date',()=>card(t.number));
 const form=el('form');
 const input=field(form,'due_date','Due date','date',t.due_date);
 input.required=true;
 const submit=el('button','Save','primary'),error=el('p');
 error.setAttribute('role','alert');
 form.append(error,submit);
 const requestId=newRequestId();
 form.onsubmit=async event=>{
   event.preventDefault();submit.disabled=true;error.textContent='';
   try{await mutate('edit',t,{due_date:input.value},requestId);await card(t.number);await screen();}
   catch(e){error.textContent=e.message;}
   finally{submit.disabled=false;}
 };
 content.append(form);
}
function confirmTaskCancellation(t){
 modal('Cancel task?',()=>card(t.number));
 const error=el('p'),actions=el('div',undefined,'actions'),requestId=newRequestId();
 error.setAttribute('role','alert');
 actions.append(button('Keep task',()=>card(t.number)),button('Cancel task',async()=>{
   try{await mutate('cancel',t,{},requestId);await card(t.number);await screen();}
   catch(e){error.textContent=e.message;}
 },'danger'));
 content.append(el('p','Cancel “'+t.title+'”? You can restore it from Archive.'),error,actions);
}
function confirmTaskDeletion(t){
 modal('Delete task?',()=>card(t.number));
 const error=el('p'),actions=el('div',undefined,'actions'),requestId=newRequestId();
 error.setAttribute('role','alert');
 actions.append(button('Back',()=>card(t.number)),button('Delete permanently',async()=>{
   try{await mutate('delete',t,{},requestId);}
   catch(e){error.textContent=e.message;return;}
   dialog.close();await screen();notice('Task deleted.');
 },'danger'));
 content.append(el('p','Task “'+t.title+'” and its history will be permanently deleted.'),error,actions);
}
function textAction(title,action,t,key){
 modal(title,()=>card(t.number));
 if(action==='return')content.append(el('p','Tell the assignee what to update. Your feedback will appear in the task.','muted'));
 const form=el('form'),input=field(form,key,action==='return'?'What needs to change?':title,'textarea');input.required=true;input.maxLength=1000;const fileInput=action==='result'?field(form,'file','Document or photo up to 10 MB','file'):null;
 if(fileInput)input.required=false;
 const requestId=newRequestId();
 const submit=el('button',action==='return'?'Send back':action==='result'?'Submit for review':'Submit','primary');form.append(submit);
 form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{
 if(fileInput?.files.length){
   const file=fileInput.files[0];
   if(file.size>10485760)throw new Error('Maximum file size is 10 MB.');
   const {response}=await requestJson('/api/files?'+new URLSearchParams({number:t.number,version:t.version,requestId}),{
     method:'POST',headers:{'content-type':file.type || 'application/octet-stream','x-file-name':encodeURIComponent(file.name),'x-caption':encodeURIComponent(input.value)},body:file});
 if(!response.ok)throw new Error(response.status===401?'Your session has expired. Reload this page to sign in again.':response.status===409?'The task has changed. Refresh its details.':'Could not save the file.');
 }else {
   const value=input.value.trim();
   if(!value)throw new Error(action==='return'?'Describe what needs to change.':'Add a result or attach a file.');
   await mutate(action,t,{[key]:value},requestId);
 }
 await card(t.number);await screen();}catch(e){notice(e.message);}finally{submit.disabled=false;}};content.append(form);
}
function edit(t,projectId){
 modal(t?'Edit task':'Create task',t?()=>card(t.number):null);const form=el('form');
 const availableProjects=projects.filter(p=>!p.archived || p.id===t?.project_id);
 select(form,'project_id','Project',[['','Select a project'],...availableProjects.map(p=>[String(p.id),p.name])],String(t?.project_id ?? projectId ?? '')).required=true;
 const title=field(form,'title','Title','text',t?.title);title.required=true;title.maxLength=120;
 field(form,'description','Description','textarea',t?.description).maxLength=1000;
 field(form,'due_date','Due date','date',t?.due_date).required=true;
 select(form,'important','Priority',importanceOptions,String(!!t?.important));
 select(form,'duration','Duration',[['','Not specified'],...durationOptions],t?.renewable?'renewable':t?.quick?'quick':'');
 const group=el('fieldset');group.append(el('legend','Assignees'));const checks=el('div',undefined,'checks');
 for(const m of members){const input=field(checks,'assignees',m.name,'checkbox');input.value=m.id;input.checked=t?t.assignees.some(x=>x.id===m.id):m.id===user.id;}group.append(checks);form.append(group);
 if(t && user.role==='admin'){
   const admins=el('fieldset');admins.append(el('legend','Responsible administrators'));
   for(const m of members.filter(m=>m.role==='admin')){
     const input=field(admins,'admins',m.name,'checkbox');input.value=m.id;input.checked=t.admins.some(x=>x.id===m.id);
   }form.append(admins);
 }
 const submit=el('button',t?'Save changes':'Create','primary');form.append(submit);
 const requestId=newRequestId();
 form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{
  const values=new FormData(form),data={...Object.fromEntries(values),assignees:values.getAll('assignees'),important:values.get('important')==='true',quick:values.get('duration')==='quick',renewable:values.get('duration')==='renewable'};
  delete data.duration;
  if(!data.assignees.length)throw new Error('Select at least one assignee.');
  if(t){data.number=t.number;data.version=t.version;
    if(String(t.project_id)===data.project_id)delete data.project_id;
    if(user.role==='admin'){data.admins=values.getAll('admins');if(!data.admins.length)throw new Error('Select a responsible administrator.');}
  }
  const result=await api('tasks',{action:t?'edit':'create',data,requestId});
  dialog.close();await screen();notice(t?'Changes saved.':'Task created.');
 }catch(e){notice(e.message);}finally{submit.disabled=false;}};content.append(form);
}
async function projectScreen(main){
 ({projects}=await api('projects'));
 ({members}=await api('members'));
 const header=el('header'),list=el('div',undefined,'card-grid');
 header.append(el('h2','Projects'));
 if(user.role==='admin')header.append(button('Create project',async()=>{
   modal('New project');const form=el('form');
   select(form,'visibility','Visibility',[['shared','Shared'],['personal','Personal']],projectVisibility);
   form.append(el('p','Personal projects are visible to their creator, assigned members and responsible administrators.','muted'));const name=field(form,'name','Title');name.required=true;name.maxLength=120;
   field(form,'description','Description','textarea');
   const owner=select(form,'owner','Responsible administrator',members.filter(m=>m.role==='admin').map(m=>[m.id,m.name]),user.role==='admin'?user.id:members.find(m=>m.role==='admin')?.id);owner.required=true;
   const submit=el('button','Create','primary');form.append(submit);
   form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{await api('projects',{action:'project_create',data:{name:name.value,description:form.elements.description.value,visibility:form.elements.visibility.value,admins:[owner.value]}});dialog.close();await screen();}catch(e){notice(e.message);}finally{submit.disabled=false;}};
   content.append(form);
 },'primary'));
 const tabs=el('div',undefined,'actions');
 for(const [value,label] of [['shared','Shared projects'],['personal','Personal projects']]){
   const tab=button(label,async()=>{projectVisibility=value;await screen();},projectVisibility===value?'primary':'quiet');
   tab.setAttribute('aria-pressed',String(projectVisibility===value));tabs.append(tab);
 }
 main.append(header,tabs,list);
 const visibleProjects=projects.filter(project=>(project.visibility ?? 'shared')===projectVisibility);
 if(!visibleProjects.length)list.append(el('p','No projects in this section.','muted'));
 for(const project of visibleProjects){
   const item=el('section',undefined,'account');item.append(el('h3',project.name),el('p',project.description ?? ''),el('p',project.archived?'Archived':'Active','muted'));
   const controls=el('div',undefined,'actions');
   controls.append(button('Open project',async()=>{
     scope='project';activeProject=project;page=0;filters={};await screen();
   }));
   if(user.role==='admin')controls.append(button('Visibility',()=>{
     modal('Project visibility',()=>{dialog.close();});
     const form=el('form'),visibility=select(form,'visibility','Visibility',[['shared','Shared'],['personal','Personal']],project.visibility ?? 'shared');
     form.append(el('p','Shared projects are listed for everyone. Personal projects are listed for their creator, assigned members and responsible administrators.','muted'));
     const save=el('button','Save','primary');form.append(save);
     form.onsubmit=async event=>{event.preventDefault();save.disabled=true;try{await api('projects',{action:'project_visibility',data:{id:project.id,visibility:visibility.value}});projectVisibility=visibility.value;dialog.close();await screen();}catch(error){notice(error.message);save.disabled=false;}};
     content.append(form);
   }),button(project.archived?'Restore':'Archive',async()=>{
     await api('projects',{action:'project_archive',data:{id:project.id,archived:!project.archived}});await screen();
   }),button('Owners',()=>{
     modal('Owners · '+project.name);const form=el('form');
     for(const m of members.filter(x=>x.role==='admin')){const input=field(form,'admins',m.name,'checkbox');input.value=m.id;input.checked=project.admins?.includes(m.id) ?? false;}
     const submit=el('button','Save','primary');form.append(submit);
     form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{const admins=new FormData(form).getAll('admins');if(!admins.length)throw new Error('Select at least one administrator.');await api('projects',{action:'project_admins',data:{id:project.id,admins}});dialog.close();await screen();}catch(e){notice(e.message);}finally{submit.disabled=false;}};
     content.append(form);
   }),button('Delete project',()=>{
     modal('Delete project?');
     content.append(el('p','Project “'+project.name+'” and all its tasks will be deleted.'));
     const error=el('p','','muted');
     error.setAttribute('role','alert');
     const actions=el('div',undefined,'actions');
     actions.append(button('Cancel',()=>dialog.close()),button('Delete',async()=>{
       try{
         await api('projects',{action:'project_delete',data:{id:project.id}});
       }catch(e){
         error.textContent=e.message;
         return;
       }
       if(String(filters.project_id)===String(project.id))delete filters.project_id;
       dialog.close();
       await screen();
       notice('Project deleted.');
     },'danger'));
     content.append(error,actions);
   }));
   item.append(controls);list.append(item);
 }
}
async function inviteMember(member){
 modal('Invite member');
 const form=el('form');
 const email=field(form,'email','Work email','email',member.corporate_email);
 email.required=true;
 email.readOnly=Boolean(member.corporate_email);
 const submit=el('button','Create link','primary');
 const message=el('p','');
 message.setAttribute('role','status');
 form.append(submit,message);
 content.append(el('p',member.name),form);
 async function issue(){
   submit.disabled=true;
   message.textContent='Creating link…';
   try{
     const {code,expiresAt}=await api('accounts',{userId:member.id,email:email.value.trim()});
     if(!dialog.open || !form.isConnected)return;
     const link=new URL('/',location.origin);
     link.hash=new URLSearchParams({code,action:'invite'});
     modal('Invitation for '+member.name);
     content.append(el('p','Share this link with the member. It expires on '+new Date(expiresAt).toLocaleString('en-GB')+'.'));
     const feedback=el('p','');
     feedback.setAttribute('role','status');
     for(const [label,value,caption] of [['Invitation link',link.href,'Copy link'],['One-time code',code,'Copy code']]){
       const input=field(content,'',label,'text',value);
       input.readOnly=true;
       input.onclick=()=>input.select();
       content.append(button(caption,async()=>{
         try{await navigator.clipboard.writeText(value);feedback.textContent='Copied';}
         catch{input.focus();input.select();feedback.textContent='Text selected. Choose Copy from your device menu.';}
       }));
     }
     content.append(feedback);
     dialog.addEventListener('close',()=>content.replaceChildren(),{once:true});
     await screen();
   }catch(e){message.textContent=e.message;submit.disabled=false;}
 }
 form.onsubmit=e=>{e.preventDefault();if(!submit.disabled)void issue();};
 if(member.corporate_email)await issue();
}
function addMember(){
 modal('Add member');
 const form=el('form'),name=field(form,'name','Member name'),error=el('p');
 name.required=true;name.maxLength=120;name.autocomplete='off';error.setAttribute('role','alert');
 const submit=el('button','Add member','primary');
 form.append(error,submit);content.append(form);
 form.onsubmit=async event=>{
   event.preventDefault();if(submit.disabled)return;
   const value=name.value.trim();
   if(!value){error.textContent='Enter a member name.';name.focus();return;}
   submit.disabled=true;error.textContent='';
   try{await api('members',{name:value});dialog.close();await screen();notice('Member added. Use Invite member to set up their access.');}
   catch(e){error.textContent=e.message;}finally{submit.disabled=false;}
 };
 name.focus();
}
function confirmMemberDeletion(member,allMembers){
 modal('Delete member?',()=>dialog.close());
 const form=el('form'),error=el('p');error.setAttribute('role','alert');
 const administrators=allMembers.filter(m=>m.id!==member.id&&m.active&&m.role==='admin');
 const preferred=administrators.find(m=>m.id===user.id) ?? administrators[0];
 content.append(el('p','Delete “'+member.name+'”? Their access will be revoked. Tasks and history will be kept.'));
 const successor=select(form,'successor','Transfer remaining responsibilities to',administrators.map(m=>[m.id,m.name]),preferred?.id ?? '');
 successor.required=true;
 if(!administrators.length)content.append(el('p','Add another active administrator before deleting this member.','muted'));
 if(member.id===user.id)content.append(el('p','Deleting your own profile will sign you out.','muted'));
 const actions=el('div',undefined,'actions'),submit=el('button','Delete member','danger');
 submit.disabled=!administrators.length;
 actions.append(button('Cancel',()=>dialog.close()),submit);form.append(error,actions);content.append(form);
 form.onsubmit=async event=>{
   event.preventDefault();if(submit.disabled)return;submit.disabled=true;error.textContent='';
   try{
     await api('accounts',{userId:member.id,successorId:successor.value},'DELETE');dialog.close();
     if(member.id===user.id){scope='mine';page=0;filters={};activeProject=null;await login();notice('Your profile has been deleted.');}
     else {await start();notice('Member deleted. Tasks and history were preserved.');}
   }catch(e){if(error.isConnected&&dialog.open)error.textContent=e.message;else notice(e.message);}
   finally{submit.disabled=!administrators.length;}
 };
}
async function accounts(main){
 const header=el('header'),list=el('div',undefined,'card-grid');
 header.append(el('h2','Members'),button('Add member',addMember,'primary'));
 main.append(header,list);
 const {members:users}=await api('accounts');
 for(const m of users){const item=el('section',undefined,'account');item.append(el('h3',m.name),el('p',(m.role==='admin'?'Administrator':'Member')+' · '+(m.active?'Active':'Disabled')+(m.corporate_email?' · '+m.corporate_email:'')+(m.email_activated?' · Sign-in activated':m.access_mail_status==='issued'?' · Code issued':m.access_mail_status==='sent'?' · Invitation sent':'')));
 const controls=el('div',undefined,'actions');
 if(m.active && !m.email_activated)controls.append(button(m.access_mail_status==='issued'?'Issue new code':'Invite member',()=>inviteMember(m)));
 controls.append(button(m.active?'Disable':'Enable',async()=>{await api('accounts',{userId:m.id,active:!m.active},'PATCH');await screen();}),
 button(m.role==='admin'?'Make member':'Make administrator',async()=>{await api('accounts',{userId:m.id,role:m.role==='admin'?'user':'admin'},'PATCH');await screen();}),
 button('Delete',()=>confirmMemberDeletion(m,users),'danger'));item.append(controls);list.append(item);}
}
const telegram=window.Telegram?.WebApp;
const systemTheme=typeof window.matchMedia==='function'?window.matchMedia('(prefers-color-scheme: dark)'):{matches:false};
function syncTheme(){
 const dark=telegram?.initData?telegram.colorScheme==='dark':systemTheme.matches;
 document.documentElement.dataset.theme=theme==='auto'?(dark?'night':'light'):theme;
}
syncTheme();
if(telegram?.initData)telegram.onEvent('themeChanged',syncTheme);
else watchTheme(systemTheme,syncTheme);
try{
 telegram?.ready();
 const params=new URLSearchParams(location.hash.slice(1)),code=params.get('code');
 if(code && ['invite','recovery'].includes(params.get('action'))){
   history.replaceState(null,'',location.pathname);await login();setup(code);
 }else{
   try{await start();}catch(e){
     if(e.status!==401 || !telegram?.initData || (await api('access-mode')).emailOnly)throw e;
     await api('telegram',{initData:telegram.initData});await start();
   }
 }
}catch(e){await login();if(e.status!==401)notice(e.message);}
