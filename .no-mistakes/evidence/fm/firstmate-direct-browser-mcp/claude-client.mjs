import {spawn} from 'node:child_process';
const root='/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DETVKKZ59NZBMVZXJ557KK';
const dir=root+'/.browser-validation';
const server={command:root+'/bin/fm-browser-mcp.sh',args:[dir+'/browser-mcp']};
const p=spawn('claude',['--bare','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--mcp-config',JSON.stringify({mcpServers:{browser:server}}),'--strict-mcp-config','--no-session-persistence'],{cwd:dir,env:{...process.env,HOME:dir+'/isolated-home',CLAUDE_CONFIG_DIR:dir+'/isolated-home/claude'},stdio:['pipe','pipe','inherit']});
let id=0,buf='';const pending=new Map();
p.stdout.on('data',d=>{buf+=d;let i;while((i=buf.indexOf('\n'))>=0){const l=buf.slice(0,i);buf=buf.slice(i+1);console.log(l);try{const m=JSON.parse(l);pending.get(m.response?.request_id)?.(m)}catch{}}});
const rpc=request=>new Promise((r,j)=>{let n=String(++id);const t=setTimeout(()=>j(Error('timeout')),25000);pending.set(n,m=>{clearTimeout(t);r(m)});p.stdin.write(JSON.stringify({type:'control_request',request_id:n,request})+'\n')});
try{
 await rpc({subtype:'initialize'});
 let r; for(let i=0;i<30;i++){r=await rpc({subtype:'mcp_status'});if(JSON.stringify(r).includes('connected'))break;await new Promise(r=>setTimeout(r,250));}
 if(!JSON.stringify(r).includes('connected'))throw Error('browser not connected');
 console.log('PASS installed Claude connects to browser through --mcp-config');
} finally {p.stdin.end();p.kill('SIGTERM');}
