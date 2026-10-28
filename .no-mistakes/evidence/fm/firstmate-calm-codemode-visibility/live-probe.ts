import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { Text } from "@earendil-works/pi-tui";
import { appendFileSync } from "node:fs";
const log=(event:any)=>appendFileSync(process.env.CALM_LIVE_LOG!,JSON.stringify({at:Date.now(),...event})+"\n");
const originalSet=globalThis.setInterval, originalClear=globalThis.clearInterval;
const timers=new Set();
globalThis.setInterval=((callback:any,ms:any,...args:any[])=>{
 const isTool=new Error().stack?.includes("toolTimerText");
 const timer=originalSet((...a:any[])=>{if(isTool)log({event:"timer-tick"});callback(...a)},ms,...args);
 if(isTool){timers.add(timer);log({event:"timer-start",active:timers.size});}
 return timer;
}) as any;
globalThis.clearInterval=((timer:any)=>{if(timers.delete(timer))log({event:"timer-clear",active:timers.size});return originalClear(timer);}) as any;
export default function(pi:any){
 pi.registerTool({name:"fixture_delay",label:"Fixture delay",description:"Disposable deterministic delay",parameters:Type.Object({outcome:Type.String()}),
  async execute(_id:any,args:any,signal:any){
   log({event:"execute",outcome:args.outcome});
   await new Promise<void>((resolve,reject)=>{const t=setTimeout(resolve,5000);signal?.addEventListener("abort",()=>{clearTimeout(t);reject(new Error("LIVE_ABORT"))},{once:true});});
   if(args.outcome==="error")throw new Error("LIVE_ERROR");
   return {content:[{type:"text",text:"LIVE_OUTPUT_"+args.outcome}]};
  },renderCall(){return new Text("UNRELATED_CUSTOM_CALL",0,0)},renderResult(r:any){return new Text("UNRELATED_CUSTOM_RESULT",0,0)}
 });
 pi.registerProvider("calm-live",{baseUrl:"http://127.0.0.1/unused",apiKey:"test-only",api:"calm-live-api",models:[{id:"local",name:"Local deterministic input",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:8192,maxTokens:256}],
  streamSimple(model:any,ctx:any){const stream=createAssistantMessageEventStream();const last=ctx.messages.at(-1);const out:any={role:"assistant",content:[],api:model.api,provider:model.provider,model:model.id,usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:"stop",timestamp:Date.now()};
   queueMicrotask(()=>{
    if(last?.role==="toolResult"){out.content=[{type:"text",text:"LIVE_DONE"}];}
    else {const prompt=typeof last?.content==="string"?last.content:JSON.stringify(last?.content);const outcome=prompt.includes("error")?"error":prompt.includes("abort")?"abort":"ok";out.stopReason="toolUse";out.content=[{type:"toolCall",id:"live-"+Date.now(),name:prompt.includes("negative")?"fixture_delay":"codemode",arguments:prompt.includes("negative")?{outcome}:{code:`text(await tools.fixture_delay({outcome:${JSON.stringify(outcome)}}));`}}];}
    stream.push({type:"start",partial:out});stream.push({type:"done",reason:out.stopReason,message:out});stream.end();
   });return stream;
  }
 });
 pi.on("tool_call",(e:any)=>{log({event:"tool-call",name:e.toolName});});
 pi.on("tool_result",(e:any)=>{log({event:"tool-result",name:e.toolName,isError:e.isError});});
 pi.on("agent_end",()=>{log({event:"agent-end",active:timers.size});});
 pi.registerCommand("probe-state",{description:"Record real timer count",handler:()=>{log({event:"probe",active:timers.size});}});
}
