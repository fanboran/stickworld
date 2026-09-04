function draw(){
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.fillStyle="#080c14";ctx.fillRect(0,0,VW,VH);
 if(view.k*40>=9){ctx.strokeStyle="#101927";ctx.lineWidth=1;ctx.beginPath();
  const x0=Math.floor(-view.x/view.k/40)*40,y0=Math.floor(-view.y/view.k/40)*40,
        x1=(-view.x+VW)/view.k,y1=(-view.y+VH)/view.k;
  for(let x=x0;x<x1;x+=40){const sx=x*view.k+view.x;ctx.moveTo(sx,0);ctx.lineTo(sx,VH);}
  for(let y=y0;y<y1;y+=40){const sy=y*view.k+view.y;ctx.moveTo(0,sy);ctx.lineTo(VW,sy);}
  ctx.stroke();}
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);
 // 泳道分组框（LOGIC-8 ACCENT 域色）
 const fr=laneFrames();
 lanes.forEach((ln,i)=>{if(laneVis[ln]===false)return;const f=fr[ln];if(!f)return;
  const c=LANE_COL[i%LANE_COL.length];
  const x=f.minX-FRAME_PAD,y=f.minY-FRAME_PAD-FRAME_TOP+14;
  const w=f.maxX-f.minX+FRAME_PAD*2,h=f.maxY-f.minY+FRAME_PAD*2+FRAME_TOP-14;
  ctx.fillStyle=c+"09";roundRect(ctx,x,y,w,h,3);ctx.fill();
  ctx.strokeStyle=c+"33";ctx.lineWidth=1;ctx.stroke();
  ctx.fillStyle=c;ctx.font="600 10px "+MONO;
  ctx.fillText("[ "+ln+" · "+f.n+" ]",x+12,y+15);
  ctx.font=FONT_SM;});
 CLUSTERS.forEach(c=>{if(folded[c.id])return;
  const ms=c.members.map(id=>byId[id]).filter(Boolean);if(!ms.length)return;
  const x0=Math.min(...ms.map(m=>m.px))-12,y0=Math.min(...ms.map(m=>m.py))-26;
  const x1=Math.max(...ms.map(m=>m.px+m.cw))+12,y1=Math.max(...ms.map(m=>m.py+m.ch))+12;
  const li=lanes.indexOf(ms[0].lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  ctx.strokeStyle=lc+"55";ctx.lineWidth=1;ctx.setLineDash([6,4]);
  roundRect(ctx,x0,y0,x1-x0,y1-y0,3);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=lc+"cc";fontSmall();ctx.textAlign="left";
  ctx.fillText("▣ "+c.name+"（点击收起）",x0+10,y0+14);});
 const anc=hi?ancestors(hi):null,des=hi?descendants(hi):null;
 const cs=(critOnly&&CRIT.length)?new Set(CRIT):null;
 const lit=id=>(!hi&&!cs)||id===hi||(anc&&anc.has(id))||(des&&des.has(id))||(cs&&cs.has(id));
 // 边（端口对端口贝塞尔）
 VE.forEach(e=>{const a=vById[e.a],b=vById[e.b];if(!a||!b||!visNode(a)||!visNode(b))return;
  const on=lit(e.a)&&lit(e.b),bad=edgeBad(e),isSel=selEdge&&selEdge.a===e.a&&selEdge.b===e.b;
  const g=edgeGeom(e);
  const isCrit=cs&&cs.has(e.a)&&cs.has(e.b);
  const sameLane=a.lane&&a.lane===b.lane;
  const li=lanes.indexOf(a.lane),laneC=LANE_COL[(li<0?0:li)%LANE_COL.length];
  let color,w;
  if(isSel||isCrit){color="#fde047";w=2.4;}                       // 选中边/关键路径=亮黄
  else if(bad){color="#f87171";w=2;}                              // 违规=红
  else if(hi===e.b){color="#38bdf8";w=2.2;}                       // 悬停节点的上游入边=天蓝
  else if(hi===e.a){color="#fbbf24";w=2.2;}                       // 悬停节点的下游出边=琥珀
  else if(byId[e.b]&&byId[e.b].claim&&byId[e.b].status!=="完成"){ // 认领任务的前置=agent 色细线（工位占用）
   color=agentColor(byId[e.b].claim)+"99";w=1.3;}
  else if(on){color="#38bdf8dd";w=2;}                             // 链高亮
  else if(sameLane){color=laneC+"88";w=1.5;}                      // 同泳道=领域色
  else{color="#243348";w=1;}                                      // 跨泳道=暗灰细
  ctx.strokeStyle=color;ctx.lineWidth=w;
  if(isCrit){ctx.setLineDash([9,7]);ctx.lineDashOffset=-(animT*0.55)%16;
   ctx.shadowColor="#fde047";ctx.shadowBlur=8;}
  else if(sameLane){ctx.setLineDash([]);}
  let ea=on?1:((hi||cs)?0.12:0.85);
  if(isCrit)ea=1;
  if(focusLane&&vById[e.a]&&vById[e.b]&&vById[e.a]._f==="other"&&vById[e.b]._f==="other")ea*=0.1;
  ctx.globalAlpha=ea;
  ctx.beginPath();ctx.moveTo(g.x1,g.y1);
  ctx.bezierCurveTo(g.c1x,g.c1y,g.c2x,g.c2y,g.x2,g.y2);ctx.stroke();
  if(bad){ctx.setLineDash([6,4]);ctx.beginPath();ctx.moveTo(g.x1,g.y1);
   ctx.bezierCurveTo(g.c1x,g.c1y,g.c2x,g.c2y,g.x2,g.y2);ctx.stroke();ctx.setLineDash([]);}
  // 箭头：沿末端切线方向
  const ang=Math.atan2(g.y2-g.c2y,g.x2-g.c2x);
  ctx.fillStyle=ctx.strokeStyle;ctx.beginPath();
  ctx.moveTo(g.x2+1,g.y2);
  ctx.lineTo(g.x2-8*Math.cos(ang-0.42),g.y2-8*Math.sin(ang-0.42));
  ctx.lineTo(g.x2-8*Math.cos(ang+0.42),g.y2-8*Math.sin(ang+0.42));
  ctx.closePath();ctx.fill();ctx.globalAlpha=1;
  if(isCrit){ctx.setLineDash([]);ctx.shadowBlur=0;}});
 // 节点
 const order=VN.slice().sort((a,b)=>((a.id===hi||a.id===sel)?1:0)-((b.id===hi||b.id===sel)?1:0));
 const vp={x0:-view.x/view.k-60,y0:-view.y/view.k-60,x1:(VW-view.x)/view.k+60,y1:(VH-view.y)/view.k+60};
 order.forEach(n=>{if(!nodeVisible(n))return;
  if(n.px+n.cw<vp.x0||n.px>vp.x1||n.py+n.ch<vp.y0||n.py>vp.y1)return;  // 视口裁剪：大数据流畅关键
  let dim=q?(n._hit?1:0.1):(hi?(n.id===hi||anc.has(n.id)||des.has(n.id)?1:0.16):1);
  if(focusLane&&n._f==="other")dim*=0.13;
  if(readyOnly&&n.status!=="完成"&&READY.indexOf(n.id)<0)dim*=0.08;
  if(cs&&!hi&&!cs.has(n.id))dim*=0.12;
  const x=n.px,y=n.py,w=n.cw,h=n.ch,c=COL[n.status];
  const li=lanes.indexOf(n.lane),lc=LANE_COL[(li<0?0:li)%LANE_COL.length];
  ctx.globalAlpha=dim;
  const isDone=n.status==="完成";
  ctx.fillStyle=isDone?lc+"1a":"#111a29";roundRect(ctx,x,y,w,h,4);ctx.fill();  // 完成=泳道色淡底（区分领域）
  ctx.strokeStyle=n.id===sel?"#f472b6":(isDone?lc:"#2b3f5a");ctx.lineWidth=n.id===sel?2:(n.tier==="微"?1:1.2);  // 完成=泳道色边框
  if(n.exempt)ctx.setLineDash([4,3]);
  roundRect(ctx,x,y,w,h,4);ctx.stroke();ctx.setLineDash([]);
  ctx.fillStyle=lc;ctx.fillRect(x+1,y+1,4,h-2);            // 泳道色条
  ctx.fillStyle=c;ctx.fillRect(x+5,y+6,3,h-12);            // 状态色条
  if(n.kind==="里程碑"){ctx.fillStyle=c;ctx.font='11px sans-serif';ctx.fillText("◆",x+14,y+17);}
  if(n.kind==="簇"){ctx.fillStyle=c;ctx.font='11px sans-serif';ctx.fillText("▣",x+14,y+17);
   fontSmall();ctx.fillStyle="#9aa7b4";
   ctx.fillText("已完 "+n._clusterDone+"/"+n._clusterN+" · 点击展开/收起",x+11,y+h-1);}
  ctx.fillStyle="#e6edf3";fontCard();ctx.textAlign="left";
  n.lines.forEach((L,i)=>ctx.fillText(L,x+18+((n.kind==="里程碑"&&i===0)?13:0),y+23+i*17));
  const claimed=n.claim&&n.status!=="完成"&&n.status!=="放弃";
  if(n.tier!=="微"){ // 状态胶囊（微任务单行卡自带状态字，跳过）
   fontSmall();
   const st=claimed?(n.claim+" · 已认领"+claimDurText(n.id)):(n.status+(n.exempt?" ·豁免":""));
   const stCol=claimed?agentColor(n.claim):c;   // 认领态胶囊=agent 色（认领标识只此一处+边框辉光，不再画顶部角标——曾与标题/编辑点三重叠加）
   const pw=ctx.measureText(st).width+12;
   ctx.fillStyle=stCol+"1f";roundRect(ctx,x+9,y+h-24,pw,16,3);ctx.fill();
   ctx.fillStyle=stCol;ctx.fillText(st,x+15,y+h-12);
   if(n.tree){ // 树注只在不溢出时画（曾无限宽直接冲出卡外）
    const tstr="⌂ "+n.tree,tw=ctx.measureText(tstr).width;
    if(x+9+pw+8+tw<x+w-6){ctx.fillStyle="#6e7a87";ctx.fillText(tstr,x+9+pw+8,y+h-12);}}}
  if(claimed){ // 已认领：agent 色边框+呼吸辉光（机场调度"航班占用"标识）
   const ac=agentColor(n.claim);
   ctx.strokeStyle=ac;ctx.lineWidth=2.2;
   const pulse=0.5+0.5*Math.sin(animT*0.07);
   ctx.shadowColor=ac;ctx.shadowBlur=3+5*pulse;
   roundRect(ctx,x,y,w,h,4);ctx.stroke();ctx.shadowBlur=0;
   if(n.id===sel){ // 选中态外扩环：认领色内框+粉色外框并存（曾内框被认领色重绘吞掉选中指示）
    ctx.strokeStyle="#f472b6";ctx.lineWidth=2;roundRect(ctx,x-3,y-3,w+6,h+6,7);ctx.stroke();}}
  if(n.tier==="微"){ // 微任务单行：点+名称+状态字（认领态右移状态字让位 ◉）
   ctx.fillStyle=c;ctx.beginPath();ctx.arc(x+10,y+h/2,3,0,7);ctx.fill();
   ctx.fillStyle="#c9d4e0";fontSmall();ctx.fillText(n.name,x+18,y+16);
   const mst=(claimed?"◉ ":"")+n.status;
   ctx.fillStyle=claimed?agentColor(n.claim):c;
   ctx.fillText(mst,x+w-ctx.measureText(mst).width-8,y+16);
   ctx.globalAlpha=1;return;}
  if(n.id!==sel&&selSet.has(n.id)){ctx.strokeStyle="#f472b688";roundRect(ctx,x-2,y-2,w+4,h+4,9);ctx.stroke();}
  if(n.id===hover&&n.id!==sel){ctx.strokeStyle="#93c5fd";ctx.lineWidth=1.5;roundRect(ctx,x-3,y-3,w+6,h+6,9);ctx.stroke();}
  if(editedIds.has(n.id)){ctx.fillStyle="#e3b341";ctx.beginPath();ctx.arc(x+w-7,y+7,3.5,0,7);ctx.fill();}
  if((n.prs||[]).indexOf(n.id)>=0){ // 自环=自复验回路：右上 ◌ 弧箭头
   ctx.strokeStyle=c;ctx.lineWidth=1.3;ctx.beginPath();ctx.arc(x+w-15,y+9,4.5,-0.6,4.2);ctx.stroke();
   ctx.fillStyle=c;ctx.beginPath();ctx.moveTo(x+w-9,y+13);ctx.lineTo(x+w-11.5,y+8.5);ctx.lineTo(x+w-6.5,y+9.5);ctx.closePath();ctx.fill();}
  ctx.globalAlpha=1;});
 ctx.textAlign="left";
 // ✈ 塔台巡航指示条（屏幕层顶部中央）
 if(towerMode){
  ctx.setTransform(dpr,0,0,dpr,0,0);
  const txt="✈ 塔台巡航中"+(sel&&byId[sel]?" · "+sel:"");
  ctx.font="600 13px "+MONO;
  const tw=ctx.measureText(txt).width;
  ctx.fillStyle="#0c2a33";ctx.fillRect(VW/2-tw/2-14,BAR_H+36,tw+28,30);
  ctx.strokeStyle="#22d3ee";ctx.lineWidth=1;ctx.strokeRect(VW/2-tw/2-14,BAR_H+36,tw+28,30);
  ctx.fillStyle="#a5f3fc";ctx.fillText(txt,VW/2-tw/2,BAR_H+56);  // 横幅在 vbar 之下（BAR_H+36 起，曾被工具条盖住上半）
  ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
 // 框选矩形 / 连线预览（屏幕层）
 if(drag&&drag.box){ctx.setTransform(dpr,0,0,dpr,0,0);
  const x=Math.min(drag.sx,drag.cx),y=Math.min(drag.sy,drag.cy),
        w=Math.abs(drag.cx-drag.sx),h=Math.abs(drag.cy-drag.sy);
  ctx.fillStyle="#38bdf81c";ctx.fillRect(x,y,w,h);
  ctx.strokeStyle="#38bdf8";ctx.setLineDash([5,4]);ctx.lineWidth=1;ctx.strokeRect(x,y,w,h);ctx.setLineDash([]);
  ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
 if(drag&&drag.link){const a=byId[drag.from];
  if(a){const x1=a.px+a.cw,y1=a.py+a.ch/2,x2=(drag.cx-view.x)/view.k,y2=(drag.cy-view.y)/view.k;
   const q3=Math.hypot(x2-x1,y2-y1)||1,dx=Math.max(30,q3*0.25);
   ctx.strokeStyle="#22d3ee";ctx.lineWidth=2;ctx.setLineDash([6,4]);
   ctx.beginPath();ctx.moveTo(x1,y1);ctx.bezierCurveTo(x1+dx,y1,x2-dx,y2,x2,y2);ctx.stroke();ctx.setLineDash([]);}}
 drawDivide();
 drawFocusLines();
 drawMini();drawZoom();
 dirty=false;}
function drawFocusLines(){if(!focusLane||!focusLines)return;
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.font='12px "Segoe UI","Microsoft YaHei",sans-serif';
 const draw=(wx,color,label)=>{const sx=wx*view.k+view.x;
  if(sx<-20||sx>VW+20)return;
  ctx.strokeStyle=color;ctx.lineWidth=2;ctx.setLineDash([8,5]);
  ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
  // 文字加底衬 chip：悬浮标注在任何画布内容（节点/边/泳道框标签）上都保持可读
  const tw=ctx.measureText(label).width;
  ctx.fillStyle="#0a111ccc";ctx.fillRect(sx+4,BAR_H+42-13,tw+10,18);
  ctx.fillStyle=color;ctx.fillText(label,sx+9,BAR_H+42);};  // 标注在 vbar 之下（曾 BAR_H+16 被工具条盖住）
 if(focusLines.pre!=null)draw(focusLines.pre,"#fbbf24","◤ 前沿（外部前置）");
 if(focusLines.post!=null)draw(focusLines.post,"#22d3ee","后继（外部被依赖）◢");
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
let showDivide=true,divideX=(DATA.divideX!=null?DATA.divideX:null),divideHover=false;
function initDivide(){if(divideX!=null)return;
 const done=VN.filter(n=>n.status==="完成");if(!done.length)return;
 divideX=Math.max(...done.map(n=>n.px+n.cw))+34;}
function enforceDivide(){if(divideX==null)return;
 // 未完成任务若在线左 → 推到线右；完成任务若在线右 → 收回线左；折叠簇成员跟随卡片
 VN.forEach(n=>{const doneSide=n.status==="完成";
  if(doneSide&&n.px+n.cw/2>divideX)n.px=divideX-8-n.cw;
  if(!doneSide&&n.px+n.cw/2<divideX)n.px=divideX+8;});
 VN.forEach(n=>{if(n.isCluster&&n.status==="完成"){
  const target=divideX-8-n.cw,dx=target-n.px;
  if(Math.abs(dx)>0.5){n.px=target;n.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;});}}});}
function drawDivide(){if(!showDivide||divideX==null)return;
 const sx=divideX*view.k+view.x;
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.fillStyle="#22d3a00d";ctx.fillRect(0,BAR_H,sx,VH-BAR_H);
 ctx.strokeStyle="#22d3a066";ctx.lineWidth=1.5;ctx.setLineDash([10,6]);
 ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.strokeStyle=divideHover?"#22d3a0":"#22d3a066";ctx.lineWidth=divideHover?2.5:1.5;
 ctx.setLineDash([10,6]);ctx.beginPath();ctx.moveTo(sx,BAR_H);ctx.lineTo(sx,VH);ctx.stroke();ctx.setLineDash([]);
 ctx.fillStyle="#22d3a0";fontSmall();ctx.textAlign="left";
 // 墙标签放墙线底部：顶部标注带留给聚拢标线/塔台横幅（曾全部挤在 BAR_H+42 同层互相叠字）
 const chip=(txt,color,dx2,dy2)=>{const tw=ctx.measureText(txt).width;
  ctx.fillStyle="#0a111ccc";ctx.fillRect(Math.max(4,sx-110)+dx2-3,VH-64+dy2-11,tw+8,16);
  ctx.fillStyle=color;ctx.fillText(txt,Math.max(4,sx-110)+dx2,VH-64+dy2);};
 chip("✂ 已完成（左）","#22d3a0",0,0);
 chip("未完成（右）","#fbbf24",122,0);
 ctx.fillStyle="#9aa7b4";ctx.font='10px sans-serif';
 const hint="⟷ 可拖动：右区整体平移·两侧独立";
 ctx.fillStyle="#0a111ccc";ctx.fillRect(Math.max(4,sx-110)-3,VH-48-10,ctx.measureText(hint).width+8,14);
 ctx.fillText(hint,Math.max(4,sx-110),VH-48);
 ctx.setTransform(dpr*view.k,0,0,dpr*view.k,dpr*view.x,dpr*view.y);}
function drawMini(){mctx.setTransform(1,0,0,1,0,0);mctx.clearRect(0,0,180,120);
 const g=graphBBox();if(!g)return;
 const s=Math.min(168/g.w,104/g.h),ox=(180-g.w*s)/2,oy=(120-g.h*s)/2;
 VN.forEach(n=>{if(!visNode(n))return;
  mctx.fillStyle=COL[n.status];
  mctx.fillRect(ox+(n.px-g.minX)*s,oy+(n.py-g.minY)*s,Math.max(2,n.cw*s),Math.max(1.5,n.ch*s));});
 const wx=(-view.x)/view.k,wy=(-view.y)/view.k;
 mctx.strokeStyle="#58a6ff";mctx.lineWidth=1;
 mctx.strokeRect(ox+(wx-g.minX)*s,oy+(wy-g.minY)*s,VW/view.k*s,VH/view.k*s);
 mini._map={s,ox,oy,g};}
function drawZoom(){
 if(!dockFolded&&dockTab==="gantt")drawGantt();  // 主图变化时同步运行图条
 const cfL=document.getElementById("cfL");if(!cfL)return;
 const vis=VN.filter(n=>visNode(n)).length;
 cfL.textContent="可见 "+vis+"/"+nodes.length+" · "+Math.round(view.k*100)+"%";
 document.getElementById("cfR").textContent="🚦 就绪 "+READY.length+" · 🛤 关键路径 "+Math.max(0,CRIT.length-1)+" 跳";
 document.getElementById("cfoot").style.display=(curView==="producer")?"none":"flex";}
function graphBBox(){const vis=VN.filter(n=>visNode(n)&&(!focusLane||n._f!=="other"));
 if(!vis.length)return null;
 const xs=vis.map(n=>n.px),ys=vis.map(n=>n.py);
 return{minX:Math.min(...xs)-60,minY:Math.min(...ys)-80,
  w:Math.max(...xs.map((v,i)=>v+vis[i].cw))-Math.min(...xs)+120,
  h:Math.max(...ys.map((v,i)=>v+vis[i].ch))-Math.min(...ys)+140};}
