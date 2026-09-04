const dock=document.getElementById("dock"),gantt=document.getElementById("gantt"),gtx=gantt.getContext("2d");
let dockFolded=false,dockTab="gantt";
document.getElementById("dockFold").onclick=()=>{dockFolded=!dockFolded;
 dock.classList.toggle("folded",dockFolded);
 document.getElementById("dockFold").textContent=dockFolded?"▴":"▾";
 sizeGantt();dirty=true;};
document.querySelectorAll("#srcSwitch").forEach(sw=>{sw.addEventListener("click",ev=>{
 const b=ev.target.closest("[data-src]");if(!b)return;ganttSource=b.dataset.src;
 sw.querySelectorAll("[data-src]").forEach(x=>x.classList.toggle("on",x===b));
 sw._built=false;sizeGantt();drawGantt();});});
document.querySelectorAll(".dtab").forEach(t=>{t.onclick=()=>{
 dockTab=t.dataset.t;
 document.querySelectorAll(".dtab").forEach(x=>x.classList.toggle("on",x.dataset.t===dockTab));
 document.getElementById("gantt").style.display=dockTab==="gantt"?"block":"none";
 document.getElementById("logList").style.display=dockTab==="log"?"block":"none";
 if(dockTab==="log")buildLogList();else{sizeGantt();drawGantt();}
};});
function toggleDock(){dockFolded=!dockFolded;dock.classList.toggle("folded",dockFolded);
 document.getElementById("dockFold").textContent=dockFolded?"▴":"▾";
 sizeGantt();if(dockTab==="log")buildLogList();dirty=true;}
addEventListener("keydown",ev=>{if(ev.key==="Tab"&&!/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)){
 ev.preventDefault();toggleDock();}});
function sizeGantt(){const c=gantt;if(!c)return;const r=c.getBoundingClientRect();
 if(r.width<10)return;c.width=r.width*dpr;c.height=r.height*dpr;}
const AGENT_COL=["#38bdf8","#a78bfa","#4ade80","#facc15","#f472b6","#22d3ee","#fb923c","#94a3b8"];
function agentColor(a){let h=0;for(const ch of a)h=(h*31+ch.charCodeAt(0))>>>0;return AGENT_COL[h%AGENT_COL.length];}
function claimDuration(task){ // 认领时长（分钟）：从真实调度日志回放
 const evs=(DATA.simlog&&DATA.simlog.events)||[];
 let t0=null;
 for(let i=evs.length-1;i>=0;i--){const e=evs[i];
  if(e.task===task&&e.action==="claim")t0=e.ts;}
 if(!t0)return null;
 const t=new Date(t0.replace(" ","T"));
 if(isNaN(t))return null;
 return Math.max(0,Math.round((Date.now()-t)/60000))+"min";}
function claimDurText(task){const m=claimDuration(task);return m?(" · "+m):"";}
let ganttSource="all",agentFilter=null;
function simEvents(){const evs=(DATA.simlog&&DATA.simlog.events)||[];
 let out=ganttSource==="all"?evs:evs.filter(e=>(e.src||"real")===ganttSource||ganttSource==="real"&&e.src!=="sim");
 if(agentFilter)out=out.filter(e=>e.agent===agentFilter||out.some(q=>q.agent===agentFilter&&q.task===e.task));
 return out;}
let SIM_T0=null;
function parseT(ts){ // 统一时间轴：sim 的 T 轮次与真实 ISO 时间都映射为相对分钟
 if(/^T\d+$/.test(ts||""))return parseInt(ts.slice(1),10);
 const t=new Date((ts||"").replace(" ","T"));
 if(isNaN(t))return 0;
 if(SIM_T0===null||t<SIM_T0)SIM_T0=t;
 return Math.max(0,Math.round((t-SIM_T0)/60000));}
let ganttJobs={};  // 运行图任务聚合（drawGantt 写入，hover/点击命中复用）
function drawGantt(){const c=gantt;if(!c||c.width<10)return;
 const evs=simEvents();
 gtx.setTransform(dpr,0,0,dpr,0,0);
 const W=c.width/dpr,H=c.height/dpr;
 gtx.fillStyle="#070c14";gtx.fillRect(0,0,W,H);
 if(view.k*40>=9){gtx.strokeStyle="#0e1725";gtx.lineWidth=1;gtx.beginPath();
  for(let x=0;x<W;x+=40){gtx.moveTo(x,0);gtx.lineTo(x,H);}for(let y=0;y<H;y+=40){gtx.moveTo(0,y);gtx.lineTo(W,y);}gtx.stroke();}
 if(!evs.length){gtx.fillStyle="#55677f";gtx.font="12px system-ui";
  gtx.fillText("无调度数据——运行 python tools/deptask/gen.py sim --agents 6 --rounds 60 生成模拟日志",20,H/2);return;}
 // 任务聚合：task → {agent,lane,t0,t1,done}
 const jobs=ganttJobs={};  // 提升为模块级：hover/点击命中复用
 evs.forEach(e=>{const j=jobs[e.task]||(jobs[e.task]={lane:e.note||"",agent:e.agent,t0:1e9,t1:-1,done:false});
  if(e.action==="claim"){j.t0=Math.min(j.t0,parseT(e.ts));j.agent=e.agent;j.lane=e.note||j.lane;}
  if(e.action==="done"){j.t1=Math.min(j.t1,parseT(e.ts));j.done=true;j.agent=e.agent;}});
 const list=Object.keys(jobs).map(id=>Object.assign({id},jobs[id]));
 let tMax=0;list.forEach(j=>{tMax=Math.max(tMax,j.done?j.t1+2:j.t0+6);});
 const padL=8,padT=8,padB=18,rowH=15;
 // 泳道带（复用 lanes 顺序 + 杂项兜底）
 const laneKeys=[];list.forEach(j=>{if(laneKeys.indexOf(j.lane)<0)laneKeys.push(j.lane);});
 lanes.forEach(l=>{if(laneKeys.indexOf(l)<0)laneKeys.push(l);});
 const bandOf={},bandNames=[];let bi=0;
 laneKeys.forEach(l=>{bandOf[l]=bi;bandNames.push(l);bi++;});
 const innerH=H-padT-padB,bandH=Math.min(46,innerH/bandNames.length);
 // x 缩放：滚轮/拖拽平移（存 ganttView）
 if(!ganttView)ganttView={t0:0,t1:tMax};
 const span=ganttView.t1-ganttView.t0||1;
 const X=t=>padL+(t-ganttView.t0)/span*(W-padL-8);
 // 刻度
 gtx.font="600 9px "+MONO;gtx.fillStyle="#55677f";
 const stepT=Math.max(1,Math.round(span/12/5)*5);
 for(let t=Math.ceil(ganttView.t0/stepT)*stepT;t<=ganttView.t1;t+=stepT){
  const x=X(t);gtx.strokeStyle="#101927";gtx.beginPath();gtx.moveTo(x,padT);gtx.lineTo(x,H-padB);gtx.stroke();
  gtx.fillText("T"+String(t).padStart(3,"0"),x+3,H-padB+11);}
 // 泳道带底 + 名称
 bandNames.forEach((l,i)=>{const y=padT+i*bandH;
  if(bi%2===0){gtx.fillStyle="#0b111c";gtx.fillRect(0,y,W,bandH);}
  const li=lanes.indexOf(l),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  gtx.fillStyle=lc+"22";gtx.fillRect(0,y,44,bandH);
  if(ganttHoverBand===l){gtx.fillStyle=lc+"14";gtx.fillRect(0,y,W,bandH);}
  gtx.fillStyle=lc;gtx.font="600 8.5px "+MONO;
  gtx.save();gtx.translate(8,y+bandH/2+3);gtx.fillText(l.length>5?l.slice(0,5):l,0,0);gtx.restore();});
 // 任务条：同带子行贪心
 const rows={};
 const sorted=list.slice().sort((a,b)=>a.t0-b.t0);
 gtx.font="600 8px "+MONO;
 sorted.forEach(j=>{const b=bandOf[j.lane]!=null?bandOf[j.lane]:bandNames.length-1;
  const y0=padT+b*bandH;
  let sub=0;
  while(rows[b+":"+sub]!=null&&rows[b+":"+sub]>j.t0)sub++;
  rows[b+":"+sub]=j.done?j.t1+2:1e9;
  const x0=Math.max(padL,X(j.t0)),x1=j.done?X(j.t1+1):W-4;
  if(x1<0||x0>W)return;
  const y=y0+4+sub*(rowH-3);
  if(y>y0+bandH-4)return;   // 带满溢出跳过（缩放或过滤可看全）
  const li=lanes.indexOf(j.lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  const ac=agentColor(j.agent);
  gtx.fillStyle=j.done?lc+"55":ac+"33";
  gtx.fillRect(x0,y,Math.max(3,x1-x0),rowH-6);
  gtx.strokeStyle=j.done?lc:ac;gtx.lineWidth=1;gtx.strokeRect(x0+.5,y+.5,Math.max(3,x1-x0)-1,rowH-7);
  if(!j.done){ // 运行中=右缘琥珀光标条
   gtx.fillStyle="#fde047";gtx.fillRect(x1-2,y,2,rowH-6);}
  if(x1-x0>34){gtx.fillStyle="#c9d4e0";gtx.fillText(j.id,x0+3,y+8);}
  if(ganttHover===j.id||(hi===j.id)){ // 双向联动：主图悬停 ↔ 运行图条高亮
   gtx.strokeStyle="#ffffffcc";gtx.lineWidth=1.5;
   gtx.strokeRect(x0-1.5,y-1.5,Math.max(4,x1-x0)+3,rowH-3);
   if(ganttHover===j.id){ // 悬停浮签：全名+agent+时段+认领时长
    const dur=claimDurText(j.id);
    const tip=j.id+" · "+(j.agent||"?")+" · T"+j.t0+"→"+(j.done?("T"+j.t1):"运行中")+(dur&&j.done===false?dur:"");
    gtx.font="600 10px "+MONO;
    const tw=gtx.measureText(tip).width+14;
    let tx=Math.min(x1+6,W-tw-4);let ty=y-24;if(ty<padT)ty=y+rowH+2;
    gtx.fillStyle="#0d1522f0";gtx.fillRect(tx,ty,tw,19);
    gtx.strokeStyle="#2b3f5a";gtx.lineWidth=1;gtx.strokeRect(tx+.5,ty+.5,tw-1,18);
    gtx.fillStyle="#eaf6ff";gtx.fillText(tip,tx+7,ty+13);}}});
 // 图例
 gtx.fillStyle="#556777";gtx.font="9px system-ui";
  gtx.fillText("■ 完成  ▌运行中（琥珀光标）  颜色=泳道域 / 描边=认领 agent  ·  滚轮缩放 · 拖拽平移 · 点条跳主图",padL,H-4);
  const sw=document.getElementById("srcSwitch");
  if(sw&&!sw._built){sw._built=true;
   const agents=[];evs.forEach(e=>{if(e.agent&&agents.indexOf(e.agent)<0)agents.push(e.agent);});
   sw.innerHTML="<span class='vt' style='border:0;cursor:default;color:var(--dim2)'>agent:</span>"+agents.map(a2=>"<button class='vt' data-ag='"+a2+"' style='border-left:3px solid "+agentColor(a2)+"' onclick=\"setAgentFilter('"+a2+"')\">"+a2+"</button>").join("")
    +"<button class='vt on' data-ag='' onclick=\"setAgentFilter(null)\">全部</button>";}}
function setAgentFilter(a){agentFilter=a||null;
 document.querySelectorAll("#srcSwitch [data-ag]").forEach(b2=>b2.classList.toggle("on",b2.dataset.ag===agentFilter));
 drawGantt();}
let ganttView=null,gDrag=null;
gantt.addEventListener("wheel",ev=>{ev.preventDefault();
 const evs=simEvents();if(!evs.length)return;
 let tMax=0;evs.forEach(e=>{tMax=Math.max(tMax,parseT(e.ts)+2);});
 if(!ganttView)ganttView={t0:0,t1:tMax};
 const f=ev.deltaY<0?0.8:1.25;
 const anchor=ganttView.t0+(ev.offsetX-8)/(gantt.clientWidth-16)*(ganttView.t1-ganttView.t0);
 let span=(ganttView.t1-ganttView.t0)*f;span=Math.min(tMax*2,Math.max(8,span));
 ganttView.t0=Math.max(0,anchor-(anchor-ganttView.t0)*f);
 ganttView.t1=ganttView.t0+span;drawGantt();},{passive:false});
gantt.addEventListener("pointerdown",ev=>{gDrag={x:ev.clientX,t0:ganttView?ganttView.t0:0,t1:ganttView?ganttView.t1:0};
 try{gantt.setPointerCapture(ev.pointerId);}catch(e2){}});
gantt.addEventListener("pointermove",ev=>{
 if(!gDrag&&ganttView){const rect=gantt.getBoundingClientRect();
  const hit=hitGantt(ev.clientX-rect.left,ev.clientY-rect.top);
  ganttHover=hit&&hit.type==="task"?hit.id:null;
  ganttHoverBand=hit&&hit.type==="band"?hit.lane:(ganttHover?(ganttJobs[ganttHover]||{}).lane:ganttHoverBand);
  if(ganttHover){hi=ganttHover;dirty=true;}   // 双向联动：运行图悬停 → 主图节点高亮
  else if(hi&&selSet.size===0&&!sel){hi=null;dirty=true;}
  return;}
 if(!gDrag||!ganttView)return;
 const span=gDrag.t1-gDrag.t0,d=(ev.clientX-gDrag.x)/(gantt.clientWidth-16)*span;
 let t0=gDrag.t0-d;ganttView={t0:Math.max(0,t0),t1:Math.max(8,t0+span)};
 if(ganttView.t0===0)ganttView.t1=Math.max(ganttView.t1,span);drawGantt();});
gantt.addEventListener("pointerup",()=>{gDrag=null;});
let ganttHover=null,ganttHoverBand=null;
function hitGantt(x,y){ // 命中检测：{type:"task",id} 或 {type:"band",lane}（空带区域=聚拢该泳道）
 const evs=simEvents();if(!evs.length)return null;
 const span=ganttView.t1-ganttView.t0,W=gantt.clientWidth-16;
 const bandKeys=[];Object.keys(ganttJobs).forEach(id=>{if(bandKeys.indexOf(ganttJobs[id].lane)<0)bandKeys.push(ganttJobs[id].lane);});
 const padT=8,bandH=Math.min(46,(gantt.clientHeight-26)/bandKeys.length);
 const hit=Object.keys(ganttJobs).find(id=>{const j=ganttJobs[id];
  const b=bandKeys.indexOf(j.lane),y0=padT+b*bandH;
  const x0=8+(j.t0-ganttView.t0)/span*W,x1=j.done?8+(j.t1+1-ganttView.t0)/span*W:W+8;
  return y>=y0&&y<=y0+bandH&&x>=x0-4&&x<=x1+4;});
 if(hit)return{type:"task",id:hit};
 const bi=Math.floor((y-padT)/bandH);
 return (bi>=0&&bi<bandKeys.length)?{type:"band",lane:bandKeys[bi]}:null;}
gantt.addEventListener("click",ev=>{ // 点条=跳主图特写；点空带=主图聚拢该泳道
 const rect=gantt.getBoundingClientRect();
 const hit2=hitGantt(ev.clientX-rect.left,ev.clientY-rect.top);
 if(!hit2)return;
 if(hit2.type==="task"){setView("graph");jump(hit2.id);}
 else if(hit2.type==="band"){setView("graph");
  const chip=[].find.call(document.querySelectorAll(".lchip"),x=>x.textContent.indexOf(hit2.lane)>=0);
  if(chip)chip.click();  // 复用泳道胶囊单击=聚拢该线
 }});
gantt.addEventListener("click",ev=>{ // 点条=跳主图特写；点空带=主图聚拢该泳道
 const rect=gantt.getBoundingClientRect();
 const hit=hitGantt(ev.clientX-rect.left,ev.clientY-rect.top);
 if(!hit)return;
 if(hit.type==="task"){setView("graph");jump(hit.id);}
 else if(hit.type==="band"){setView("graph");
  const chip=[].find.call(document.querySelectorAll(".lchip"),x=>x.textContent.indexOf(hit.lane)>=0);
  if(chip)chip.click();  // 复用泳道胶囊单击=聚拢该线
 }});
function buildLogList(){const evs=simEvents().slice().reverse();
 const el=document.getElementById("logList");
 el.innerHTML=evs.map(e=>"<div class='lst' onclick='sideSelect(\""+e.task+"\")' onmouseenter='hi=\""+e.task+"\";dirty=true'>"
  +"<span class='dot' style='background:"+agentColor(e.agent)+"'></span>"
  +"<span class='lid'>"+e.ts+"</span><span class='lname'>"+e.agent+" → "+e.action+" "+e.task+"</span>"
  +"<span class='lgo'>⤢</span></div>").join("")
  ||"<div class='ph'>无调度日志</div>";}
window.addEventListener("resize",()=>{sizeGantt();drawGantt();});
