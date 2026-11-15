const statuses = {new:'New', in_progress:'In progress', review:'In review', done:'Done', cancelled:'Cancelled'};
const button = (text, callback_data) => ({text, callback_data});
const baseMenu = [[button('Create task','create'), button('My tasks','list:0')],[button('Due today','today:0'),button('Overdue','overdue:0')],[button('Projects','projects')]];
const date = value => value.split('-').reverse().join('.');
const created = new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Moscow', dateStyle:'short'});
const details = t => [t.title, t.project && 'Project: '+t.project, t.description,
  t.important ? 'Important' : 'Normal', t.renewable ? 'Recurring' : t.quick && 'Quick',
  t.assignees && 'Assignees: '+t.assignees.map(x=>x.name).join(', '),
  t.admins && 'Owners: '+t.admins.map(x=>x.name).join(', '),
  'Due: '+date(t.due_date)].filter(Boolean);

export function render(screen) {
  const lines = [screen.message];
  const menu = screen.admin ? [...baseMenu,[button('All tasks','all:0')]] : baseMenu;
  let keyboard = [];
  if (screen.task) {
    const t = screen.task;
    lines.push('Task', ...details(t), 'Created: '+created.format(new Date(t.created_at)),
      'Status: '+statuses[t.status], t.result && 'Result: '+t.result);
    for (const file of t.attachments ?? []) keyboard.push([button('📎 '+file.name.slice(0,45),'attachment:'+file.id)]);
    const assigned=t.assignees?.some(m=>m.id===screen.actor_id) ?? true;
    if (t.status==='new' && assigned) keyboard.push([button('Start work','begin:'+t.number+':'+t.version)]);
    if (t.status==='in_progress' && assigned) keyboard.push([button('Submit result','result:'+t.number+':'+t.version)]);
    if(screen.admin && !['done','cancelled'].includes(t.status))keyboard.push([button('Owners','task_team:'+t.number+':'+t.version)]);
    if (screen.admin && t.status==='review') keyboard.push([button('Approve','approve:'+t.number+':'+t.version),button('Return to progress','return:'+t.number+':'+t.version)]);
    if ((screen.admin || screen.actor_id===t.author_id) && !['done','cancelled'].includes(t.status)) keyboard.push([button('Cancel task','cancel_task:'+t.number+':'+t.version)]);
    if ((screen.admin || screen.actor_id===t.author_id) && !['done','cancelled'].includes(t.status))
      keyboard.push([button('Edit','edit:'+t.number+':'+t.version)]);
    if(t.project_id)keyboard.push([button('Back to project','project_open:'+t.project_id+':0')]);
    keyboard.push(...menu);
  } else if (screen.delete_project) {
    const project=screen.delete_project;
    lines.push('Delete project “'+project.name+'»?');
    keyboard.push([button('Delete project','project_delete_confirm:'+project.id),button('Cancel','projects')]);
  } else if (screen.projects) {
    lines.push('Projects');
    for (const project of screen.projects) {
      keyboard.push([button('Open · '+project.name,'project_open:'+project.id+':0')]);
      if(screen.admin)keyboard.push([button('Owners · '+project.name,'project_team:'+project.id)]);
      lines.push(project.name+(project.archived?' (archived)':''));
      if (screen.admin) keyboard.push([button(
        (project.archived?'Restore ':'Archive ')+project.name,
        (project.archived?'restore:':'archive:')+project.id)]);
    }
    if (screen.admin) keyboard.push([button('Create project','project_new')]);
    keyboard.push([button('Menu','menu')]);
  } else if (screen.filter_options) {
    lines.push('Select a filter');
    for(const option of screen.filter_options) keyboard.push([button(option.name,option.action)]);
    keyboard.push([button('All tasks','all:0'),button('Menu','menu')]);
  } else if (screen.tasks) {
    const project=screen.selected_project;
    const title=project?.name ?? ({today:'Due today',overdue:'Overdue',all:'All tasks'})[screen.scope] ?? 'My tasks';
    lines.push(title+' · page '+(screen.page+1));
    if(!screen.tasks.length)lines.push('No tasks on this page.');
    if(project && !project.archived)keyboard.push([button('Create task','create:'+project.id)]);
    for (const t of screen.tasks.slice(0,5)) {
      keyboard.push([button(t.title.slice(0,50)+' · '+statuses[t.status],'open:'+t.number)]);
    }
    if(screen.admin)keyboard.push([button('Filters','filters')]);
    const nav = [];
    if (screen.page) nav.push(button('← Back',((screen.scope || 'list')+':')+(screen.page-1)));
    if (screen.tasks.length>5) nav.push(button('Next →',((screen.scope || 'list')+':')+(screen.page+1)));
    if (nav.length) keyboard.push(nav);
    if(project && screen.admin)keyboard.push([button('Delete project','project_delete:'+project.id)]);
    if(project)keyboard.push([button('Projects','projects')]);
    keyboard.push([button('Menu','menu')]);
  } else if (['admin_project','admin_task'].includes(screen.step)) {
    const token=screen.draft.token;
    lines.push('Select responsible administrators.');
    for(const m of screen.admin_options)keyboard.push([button((m.selected?'✓ ':'')+m.name,'admin_pick:'+token+':'+m.id)]);
    keyboard.push([button('Save','admin_save:'+token),button('Cancel','abort:'+token)]);
  } else if (screen.step?.startsWith('form_')) {
    const d=screen.draft;
    const action=(label,key,value)=>button(label,key+':'+d.token+(value?':'+value:''));
    const prompts={
      form_project:'Select a project.',form_title:'Enter the task title.',
      form_description:'Add a description or skip this step.',form_flags:'Select task flags.',
      form_date:'Enter the due date as DD.MM.YYYY.',form_assignees:'Select assignees.',
      form_preview:'Review the task before saving.'
    };
    if(d.project && screen.step!=='form_preview')lines.push('Project: '+d.project);
    lines.push(prompts[screen.step]);
    if (screen.step==='form_project') {
      for (const p of screen.options) keyboard.push([action(p.name,'pick',String(p.id))]);
    }
    if (screen.step==='form_description') keyboard.push([action('Skip','skip')]);
    if (screen.step==='form_flags') {
      keyboard.push([action((d.important?'✓ ':'')+'Important','flag','important'),action((!d.important?'✓ ':'')+'Normal','flag','neutral')]);
      keyboard.push([action((d.quick?'✓ ':'')+'Quick','flag','quick'),action((d.renewable?'✓ ':'')+'Recurring','flag','renewable')]);
      keyboard.push([action((!d.quick&&!d.renewable?'✓ ':'')+'No duration','flag','ordinary')]);
      keyboard.push([action('Next','next')]);
    }
    if (screen.step==='form_assignees') {
      for (const member of screen.options) keyboard.push([action((member.selected?'✓ ':'')+member.name,'pick',member.id)]);
      keyboard.push([action('Next','next')]);
    }
    if (screen.step==='form_preview') {
      lines.push(...details({...d,assignees:screen.options.filter(x=>x.selected)}));
      keyboard.push([action('Save','save')]);
    }
    keyboard.push([action('Back','back'),action('Cancel','abort')]);
  } else if (screen.step==='menu') {
    lines.push('Choose an action.'); keyboard=menu;
  } else if (screen.step) {
    const d=screen.draft;
    const action=(label,key)=>button(label,key+':'+d.token);
    const prompts={project_name:'Enter the new project name.',review_reason:'Enter the reason for returning the task to progress.',title:'Enter the task title.', description:'Add a description or press Skip.',
      date:'Enter the due date as DD.MM.YYYY.', preview:'Review the task before saving.',
      result:'Submit text, a link, a document or a photo up to 10 MB for review.'};
    lines.push(prompts[screen.step]);
    if (screen.step==='description') keyboard.push([action('Skip','skip')]);
    if (screen.step==='preview') {
      lines.push(...details(d)); keyboard.push([action('Save','save')]);
    }
    keyboard.push([action('Back','back'),action('Cancel','abort')]);
  }
  return {text:lines.filter(Boolean).join('\n'), reply_markup:{inline_keyboard:keyboard}};
}
