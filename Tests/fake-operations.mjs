import { homedir } from "node:os";
// Inert local protocol fixture. No account, network or transcript logging.
let input = ''; for await (const chunk of process.stdin) input += chunk;
const request = JSON.parse(input);
const scenario = process.argv[process.argv.indexOf('--config') + 1];
if (process.argv.includes('--catalog')) {
  const catalog = {version:1,operation:'catalog',status:'ok',selected:{provider:'fixture',model:'sample',effort:'low'},providers:[{id:'fixture',label:'Fixture',available:true,models:[{id:'sample',label:'Sample',vision:true,efforts:['low','high'],defaultEffort:'low',operations:['screen_ask','edit_selection']}]}]};
  if (scenario === 'catalog-no-effort') { catalog.selected.effort = 'default'; catalog.providers[0].models[0].efforts = []; catalog.providers[0].models[0].defaultEffort = 'default'; }
  if (scenario === 'catalog-unresolved') { catalog.selected = null; catalog.reason = 'saved_model_unavailable'; }
  process.stdout.write(JSON.stringify(catalog));
  process.exit(0);
}
const result = {version:1,operation:request.operation,status:'ok',text:request.selection ?? request.transcript};
if (scenario === 'malformed') { process.stdout.write('{'); process.exit(0); }
if (scenario === 'hang') { await new Promise(() => { setInterval(()=>{},1000); }); }
if (scenario === 'nonzero') process.exit(3);
if (scenario === 'wrong-operation') result.operation = 'dictate';
if (scenario === 'wrong-version') result.version = 2;
if (scenario === 'control') result.text += '\u0000';
if (scenario === 'whitespace') result.text = ' \t\r\n ';
if (scenario === 'extra-whitespace') result.text = ' ' + result.text;
if (scenario === 'trimmed') result.text = result.text.trim();
if (scenario === 'error') { result.status = 'error'; delete result.text; }
if (scenario === 'fallback') { result.status = 'fallback'; result.text = request.instruction ?? request.transcript; }
if (scenario === 'snippet') { delete result.text; result.snippets = [{trigger:'my signoff',expansion:request.context}]; }
if (scenario === 'invented') { delete result.text; result.snippets = [{trigger:'my signoff',expansion:'UNSUPPLIED'}]; }
if (scenario.startsWith('assistant-')) {
  result.kind = 'answer'; result.text = 'Fixture answer';
  if (scenario === 'assistant-wrong-kind') result.kind = 'tool_call';
  if (scenario === 'assistant-actions') { result.kind = 'actions'; result.actions = [{type:'open_app',appId:'com.google.Chrome'}]; }
  if (scenario.startsWith('assistant-action-')) { const type=scenario.slice('assistant-action-'.length); result.kind='actions'; result.actions=[{click:{type,x:0.5,y:0.5},type:{type,text:'Retired'},key:{type,key:'enter'},scroll:{type,direction:'down',amount:1},open_app:{type,appId:'com.google.Chrome'},open_url:{type,url:'https://example.test'},wait:{type,milliseconds:750}}[type]]; }
  if (scenario === 'assistant-answer-malformed-actions') result.actions = {type:'click'};
  if (scenario === 'assistant-answer-malformed-artifacts') result.artifacts = ['retired'];
  if (scenario === 'assistant-answer-actions') result.actions = [{type:'click',x:0.5,y:0.5}];
  if (scenario === 'assistant-answer-artifacts') result.artifacts = {blendPath:'/tmp/retired.blend',previewPath:'/tmp/retired.png'};
  if (scenario === 'assistant-error') { result.status = 'error'; delete result.text; }
  if (scenario === 'assistant-timeout') { result.status = 'error'; result.reason = 'timeout'; delete result.text; }
  if (scenario === 'assistant-private-reason') { result.status = 'error'; result.reason = 'PRIVATE WORDS\nPRIVATE CREDENTIAL'; delete result.text; }
  if (scenario === 'assistant-blender') { result.kind = 'blender'; result.artifacts = {blendPath:homedir()+'/Library/Application Support/Sona/Creations/Scene-fixture/Scene.blend',previewPath:homedir()+'/Library/Application Support/Sona/Creations/Scene-fixture/Preview.png'}; }
  if (scenario === 'assistant-invalid-path') { result.kind = 'blender'; result.artifacts = {blendPath:'relative.blend',previewPath:'relative.png'}; }
}
process.stdout.write(JSON.stringify(result));
