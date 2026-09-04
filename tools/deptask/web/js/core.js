"use strict";
const cv=document.getElementById("cv"),ctx=cv.getContext("2d");
const mini=document.getElementById("mini"),mctx=mini.getContext("2d");
const STATUS=["完成","待验收","进行中","可开工","阻塞","冻结","放弃"];
const ACTIVE=new Set(["进行中","待验收","完成"]);
const COL={"完成":"#22d3a0","待验收":"#fbbf24","进行中":"#fde047","可开工":"#38bdf8","阻塞":"#64748b","冻结":"#94a3b8","放弃":"#55677f"};
const LANE_COL=["#38bdf8","#a78bfa","#fb923c","#4ade80","#facc15","#f472b6","#22d3ee","#94a3b8"];
const FRAME_PAD=18,FRAME_TOP=34;
let BAR_H=80;  // 顶栏实际高度（resize 动态测量）：画布内容/分隔墙/聚拢标注从这条线以下开始
let dpr=1,VW=0,VH=0,animT=0;
const MONO='ui-monospace,"SF Mono","Cascadia Mono",Consolas,monospace';
const FONT_SM='11px "Segoe UI","Microsoft YaHei",sans-serif';
let nodes=DATA.nodes,edges=DATA.edges,lanes=DATA.lanes;
const manual0=nodes.some(n=>n.x!=null);
nodes.forEach(n=>{n.px=n.x!=null?n.x:0;n.py=n.y!=null?n.y:0;n.lines=[];n.cw=150;n.ch=56;n.inP=[];n.outP=[];});
const byId={};nodes.forEach(n=>byId[n.id]=n);
const prsOf={},blocksOf={};
nodes.forEach(n=>{prsOf[n.id]=[];blocksOf[n.id]=[];});
edges.forEach(e=>{if(prsOf[e.b]){prsOf[e.b].push(e.a);blocksOf[e.a].push(e.b);}});
nodes.forEach(n=>{(n.prs||[]).forEach(p=>{if(prsOf[n.id].indexOf(p)<0)prsOf[n.id].push(p);});});
let view={x:0,y:0,k:1},sel=null,selSet=new Set(),selEdge=null,hover=null,drag=null,hi=null,q="",dirty=true;
let spaceDown=false,editedIds=new Set(),dirtyEdits=false;
let laneVis={};lanes.forEach(l=>laneVis[l]=true);
// ── 簇（封装任务簇）：折叠时成员由虚拟簇节点代替，边聚合重定向 ──
const CLUSTERS=DATA.clusters||[];
const folded={},memberOf={};
CLUSTERS.forEach(c=>{folded[c.id]=!!c.folded;c.members.forEach(m=>memberOf[m]=c.id);});
let VN=[],VE=[],vById={};  // 视图层：当前生效的节点/边（折叠感知）
const ST_ORDER=["进行中","待验收","冻结","阻塞","可开工","完成","放弃"];
function aggStatus(ms){const has={};ms.forEach(m=>has[m.status]=1);
 for(const s of ST_ORDER)if(has[s])return s;return"阻塞";}
function rebuildView(){
 const inFolded=id=>memberOf[id]&&folded[memberOf[id]];
 VN=nodes.filter(n=>!inFolded(n.id));
 CLUSTERS.forEach(c=>{if(!folded[c.id])return;
  const ms=c.members.map(id=>byId[id]).filter(Boolean);
  const cx=ms.reduce((s,m)=>s+m.px+m.cw/2,0)/ms.length;
  const cy=ms.reduce((s,m)=>s+m.py+m.ch/2,0)/ms.length;
  const done=ms.filter(m=>m.status==="完成").length;
  const laneC={};ms.forEach(m=>laneC[m.lane]=(laneC[m.lane]||0)+1);
  const lane=Object.keys(laneC).sort((a,b)=>laneC[b]-laneC[a])[0]||"";
  VN.push({id:"簇:"+c.id,name:c.name,kind:"簇",lane:lane,status:aggStatus(ms),
   px:cx-110,py:cy-32,cw:220,ch:64,lines:[],inP:[],outP:[],isCluster:c,
   prs:c.members.flatMap(id=>prsOf[id]).filter(p=>!c.members.includes(p)),
   note:c.note,_clusterDone:done,_clusterN:ms.length});});
 const seen={};VE=[];vById={};VN.forEach(n=>vById[n.id]=n);
 edges.forEach(e=>{const a=inFolded(e.a)?"簇:"+memberOf[e.a]:e.a;
  const b=inFolded(e.b)?"簇:"+memberOf[e.b]:e.b;
  if(a===b)return;const k=a+"→"+b;if(seen[k])return;seen[k]=1;VE.push({a,b});});
 const vc=VN.filter(n=>n.isCluster);
 vc.forEach(v=>measureOne(v,236));
 // 聚拢模式与完成分割墙互斥：墙的左右强制对齐会拉散聚拢的 core/pre/post 布局
 if(!focusLane&&divideX==null){const done=VN.filter(n=>n.status==="完成");
  if(done.length)divideX=Math.max(...done.map(n=>n.px+n.cw))+34;}
 if(!focusLane)enforceDivide();
 computePorts();}
function measureOne(n,maxW){ // 单节点卡片测量（簇节点用更大宽度）
 n.lines=wrap(n.name,maxW,2);
 let w=0;n.lines.forEach(L=>w=Math.max(w,ctx.measureText(L).width));
 fontSmall();
 const extra=n.isCluster?26:0;
 const pw=ctx.measureText(n.status+(n.exempt?" ·豁免":"")).width+16;
 const idw=ctx.measureText(n.id).width;
 n.cw=Math.max(128,Math.min(n.isCluster?260:202,Math.max(w+22,pw+10,idw+18)));
 n.ch=11+n.lines.length*17+7+18+extra;}
function ancestors(id){const s=new Set(),st=[id];while(st.length){(prsOf[st.pop()]||[]).forEach(p=>{if(!s.has(p)){s.add(p);st.push(p);}});}return s;}
function descendants(id){const s=new Set(),st=[id];while(st.length){(blocksOf[st.pop()]||[]).forEach(b=>{if(!s.has(b)){s.add(b);st.push(b);}});}return s;}
function laneHidden(l){return l&&laneVis[l]===false;}
let viewFilter={};  // 岗位视图过滤（页签切换设置）：lanes=可见线集合 / ids=按任务判定函数
let statusFilter=new Set(),microOn=true,doneOn=true;  // view-bar 筛选态（跨视图保留）
function visNode(n){
 if(laneHidden(n.lane))return false;
 if(viewFilter.lanes&&!viewFilter.lanes.has(n.lane))return false;
 if(viewFilter.ids&&!viewFilter.ids(n))return false;
 if(statusFilter.size&&!statusFilter.has(n.status))return false;
 if(n.tier==="微"&&!microOn)return false;
 if(n.status==="完成"&&!doneOn)return false;
 return true;}
function nodeVisible(n){return visNode(n)&&(!q||n._hit);}
function resize(){dpr=window.devicePixelRatio||1;VW=innerWidth;VH=innerHeight;
 BAR_H=document.getElementById("bar").offsetHeight||80;  // 窄屏换行/媒体查询后顶栏高度跟随实测
 const top=BAR_H+"px";["sideL","sideR","dash"].forEach(id2=>{const el=document.getElementById(id2);
  if(el&&el.style.display!=="none")el.style.top=top;});
 const vb=document.getElementById("vbar");  // vbar 也要跟随：曾漏同步——顶栏后长高时 vbar 停在旧 top 被顶栏压住
 if(vb&&vb.style.display!=="none"){vb.style.top=top;const sw=sideW();vb.style.left=sw.L+"px";vb.style.right=sw.R+"px";}
 cv.width=VW*dpr;cv.height=VH*dpr;cv.style.width=VW+"px";cv.style.height=VH+"px";dirty=true;}
addEventListener("resize",resize);resize();
function roundRect(c,x,y,w,h,r){c.beginPath();c.moveTo(x+r,y);c.arcTo(x+w,y,x+w,y+h,r);
 c.arcTo(x+w,y+h,x,y+h,r);c.arcTo(x,y+h,x,y,r);c.arcTo(x,y,x+w,y,r);c.closePath();}
function fontCard(){ctx.font='600 12.5px "Segoe UI","Microsoft YaHei",sans-serif';}
function fontSmall(){ctx.font='11px "Segoe UI","Microsoft YaHei",sans-serif';}
function wrap(text,maxW,maxLines){fontCard();const out=[];let cur="";
 for(const ch of text){const t=cur+ch;
  if(ctx.measureText(t).width>maxW&&cur){out.push(cur);cur=ch;
   if(out.length===maxLines-1){let rest=text.slice(text.indexOf(cur));
    while(rest&&ctx.measureText(rest+"…").width>maxW)rest=rest.slice(0,-1);
    out.push(rest+"…");return out;}}
  else cur=t;}
 if(cur)out.push(cur);return out;}
function measureCards(){fontCard();
 nodes.forEach(n=>{n.lines=wrap(n.name,186,2);
  let w=0;n.lines.forEach(L=>w=Math.max(w,ctx.measureText(L).width));
  fontSmall();const pw=ctx.measureText(n.status+(n.exempt?" ·豁免":"")).width+16;
  const idw=ctx.measureText(n.id).width;
  if(n.tier==="微"){ // 微任务：单行矮卡（几轮可完成的挂载项）
   n.lines=wrap(n.name,150,1);
   n.cw=Math.max(96,Math.min(170,w+20));n.ch=26;return;}
  n.cw=Math.max(128,Math.min(202,Math.max(w+22,pw+10,idw+18)));
  n.ch=11+n.lines.length*17+7+18;});}
