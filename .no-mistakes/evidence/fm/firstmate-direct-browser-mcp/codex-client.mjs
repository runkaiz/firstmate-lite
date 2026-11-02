import {spawn} from 'node:child_process';
import fs from 'node:fs';
const root='/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DETVKKZ59NZBMVZXJ557KK';
const dir=root+'/.browser-validation';
const server={command:root+'/bin/fm-browser-mcp.sh',args:[dir+'/browser-mcp']};
fs.mkdirSync(dir+'/isolated-home/codex',{recursive:true});
const override=`mcp_servers.browser={command=${JSON.stringify(server.command)},args=${JSON.stringify(server.args)},enabled=true}`;
const p=spawn('codex',['-c',override,'app-server'],{cwd:dir,env:{...process.env,CODEX_HOME:dir+'/isolated-home/codex',HOME:dir+'/isolated-home'},stdio:['pipe','pipe','inherit']});
let id=0,buf='';const pending=new Map();
p.stdout.on('data',d=>{buf+=d;let i;while((i=buf.indexOf('\n'))>=0){const l=buf.slice(0,i);buf=buf.slice(i+1);console.log(l);try{const m=JSON.parse(l);pending.get(m.id)?.(m)}catch{}}});
const rpc=(method,params)=>new Promise((r,j)=>{let n=++id;const t=setTimeout(()=>j(Error(method+' timeout')),25000);pending.set(n,m=>{clearTimeout(t);r(m)});p.stdin.write(JSON.stringify({id:n,method,params})+'\n')});
try{
 await rpc('initialize',{clientInfo:{name:'browser-validation',version:'1'},capabilities:{experimentalApi:true}});
 p.stdin.write(JSON.stringify({method:'initialized'})+'\n');
 const r=await rpc('mcpServerStatus/list',{});
 if(!JSON.stringify(r).includes('navigate_page'))throw Error('Browser tools absent');
 console.log('PASS installed Codex connects to the pinned MCP and discovers navigate_page');
} finally {p.stdin.end();p.kill('SIGTERM');}
