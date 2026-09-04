function dagreLayout(){
 // 分区布局：完成子图与未完成子图各自独立 dagre，墙 = 两区中缝
 // 关键：只排「可见」节点——岗位视图过滤掉的任务不参与分层，否则隐藏节点占位把可见任务撑散
 const vis=VN.filter(n=>visNode(n));
 const D=vis.filter(n=>n.status==="完成"),U=vis.filter(n=>n.status!=="完成");
 layoutSub(D,30);
 const dRight=D.length?Math.max(...D.map(n=>n.px+n.cw)):0;
 layoutSub(U,dRight+110);
 divideX=(D.length?dRight:0)+55;
 computePorts();}
function layoutSub(set,gapLeft){
 if(!set.length)return;
 const g=new dagre.graphlib.Graph({multigraph:true});
 g.setGraph({rankdir:"LR",nodesep:26,ranksep:78,marginx:30,marginy:30});
 g.setDefaultEdgeLabel(()=>({}));
 const ids=new Set(set.map(n=>n.id));
 set.forEach(n=>g.setNode(n.id,{width:n.cw,height:n.ch}));
 VE.forEach(e=>{if(ids.has(e.a)&&ids.has(e.b))g.setEdge(e.a,e.b,{minlen:1,weight:2});});
 dagre.layout(g);
 let minX=1e9;set.forEach(n=>{const gn=g.node(n.id);minX=Math.min(minX,gn.x-n.cw/2);});
 set.forEach(n=>{const gn=g.node(n.id);const nx=gn.x-n.cw/2-minX+gapLeft,ny=gn.y-n.ch/2;
  if(n.isCluster){const dx=nx-n.px,dy=ny-n.py;
   n.px=nx;n.py=ny;
   n.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;m.py+=dy;});}
  else{n.px=nx;n.py=ny;}});
}
function computePorts(){
 VN.forEach(n=>{n.inP=[];n.outP=[];});
 VE.forEach(e=>{const a=vById[e.a],b=vById[e.b];if(!a||!b)return;
  a.outP.push({e,y:0});b.inP.push({e,y:0});});
 VN.forEach(n=>{
  const sortIn={},sortOut={};
  VE.forEach(e=>{if(e.b===n.id){const a=vById[e.a];if(a)sortIn[e.a+"|"+e.b]=a.py+a.ch/2;}
   if(e.a===n.id){const b=vById[e.b];if(b)sortOut[e.a+"|"+e.b]=b.py+b.ch/2;}});
  n.inP.sort((p,q)=>(sortIn[p.e.a+"|"+p.e.b]||0)-(sortIn[q.e.a+"|"+q.e.b]||0));
  n.outP.sort((p,q)=>(sortOut[p.e.a+"|"+p.e.b]||0)-(sortOut[q.e.a+"|"+q.e.b]||0));
  n.inP.forEach((p,i)=>p.y=n.py+n.ch*(i+1)/(n.inP.length+1));
  n.outP.forEach((p,i)=>p.y=n.py+n.ch*(i+1)/(n.outP.length+1));});}
function edgeGeom(e){ // litegraph SPLINE_LINK：控制点 = 端口方向 × 0.25×间距
 const a=vById[e.a],b=vById[e.b];
 const pa=a.outP.find(p=>p.e===e),pb=b.inP.find(p=>p.e===e);
 const x1=a.px+a.cw,y1=pa?pa.y:a.py+a.ch/2;
 const x2=b.px,y2=pb?pb.y:b.py+b.ch/2;
 const q=Math.hypot(x2-x1,y2-y1)||1,dx=Math.max(30,q*0.25);
 return{x1,y1,x2,y2,c1x:x1+dx,c1y:y1,c2x:x2-dx,c2y:y2};}
function edgeBad(e){const a=vById[e.a],b=vById[e.b];
 return a&&b&&a.status!=="完成"&&ACTIVE.has(b.status);}
const COLW=240;
function laneBandLayout(){ // 泳道带状布局 v2：行=泳道水平带，列=依赖深度（同带同深度垂直堆叠）——横平竖直
 const vis=VN.filter(n=>visNode(n));
 const visIds=new Set(vis.map(n=>n.id));
 const deps={},depth={},visiting=new Set();
 vis.forEach(n=>deps[n.id]=(n.prs||[]).filter(p=>visIds.has(p)&&p!==n.id));
 function dp(i){if(depth[i]!=null)return depth[i];if(visiting.has(i))return 0;
  visiting.add(i);
  const d=deps[i].length?1+Math.max(...deps[i].map(dp)):0;
  visiting.delete(i);depth[i]=d;return d;}
 vis.forEach(n=>dp(n.id));
 const laneIdx={};lanes.forEach((l,i)=>laneIdx[l]=i);
 const doneVis=vis.filter(n=>n.status==="完成"),undoneVis=vis.filter(n=>n.status!=="完成");
 function place(set,x0){
  const bands={};
  set.forEach(n=>{const li=laneIdx[n.lane]!=null?laneIdx[n.lane]:999;bands[li]=bands[li]||[];bands[li].push(n);});
  let yBase=30;
  Object.keys(bands).map(Number).sort((a,b)=>a-b).forEach(li=>{
   const arr=bands[li].sort((a,b)=>(depth[a.id]-depth[b.id])||(a.id<b.id?-1:1));
     const cols={};                                   // depth 列 → 垂直堆叠队列
   arr.forEach(n=>{(cols[depth[n.id]]=cols[depth[n.id]]||[]).push(n);});
   let bandH=0;
   Object.keys(cols).map(Number).sort((a,b)=>a-b).forEach(d=>{
    cols[d].forEach((n,i)=>{
     n.px=x0+d*COLW;
     n.py=yBase+i*(n.ch+8);
     bandH=Math.max(bandH,(i+1)*(n.ch+8));});});
   yBase+=bandH+24;});
  return yBase;}
 let endY=place(doneVis,30);
 const dMax=doneVis.length?Math.max(...doneVis.map(n=>n.px+n.cw)):0;
 endY=Math.max(endY,place(undoneVis,dMax+110));
 divideX=(doneVis.length?dMax:0)+55;
 computePorts();}
function laneFrames(){
 const fr={};
 VN.forEach(n=>{if(!n.lane||!visNode(n))return;
  const f=fr[n.lane]||(fr[n.lane]={minX:1e9,minY:1e9,maxX:-1e9,maxY:-1e9,n:0});
  f.minX=Math.min(f.minX,n.px);f.minY=Math.min(f.minY,n.py);
  f.maxX=Math.max(f.maxX,n.px+n.cw);f.maxY=Math.max(f.maxY,n.py+n.ch);f.n++;});
 return fr;}
