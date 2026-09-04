function toWorld(ev){return{x:(ev.clientX-view.x)/view.k,y:(ev.clientY-view.y)/view.k};}
function nodeAt(x,y){for(let i=VN.length-1;i>=0;i--){const n=VN[i];
 if(!nodeVisible(n))continue;
 if(x>=n.px&&x<=n.px+n.cw&&y>=n.py&&y<=n.py+n.ch)return n;}return null;}
function portAt(x,y){for(let i=VN.length-1;i>=0;i--){const n=VN[i];   // 输出热区：右缘外 9px
 if(!nodeVisible(n)||n.isCluster)continue;
 if(x>=n.px+n.cw-1&&x<=n.px+n.cw+9&&y>=n.py&&y<=n.py+n.ch)return n;}return null;}
function bez(t,g){const u=1-t;return{x:u*u*u*g.x1+3*u*u*t*g.c1x+3*u*t*t*g.c2x+t*t*t*g.x2,
 y:u*u*u*g.y1+3*u*u*t*g.c1y+3*u*t*t*g.c2y+t*t*t*g.y2};}
function edgeAt(x,y){let best=null,bd=8;VE.forEach(e=>{const g=edgeGeom(e);
 for(let i=0;i<=16;i++){const q2=bez(i/16,g),d=Math.hypot(q2.x-x,q2.y-y);if(d<bd){bd=d;best=e;}}});
 return best;}
function markEdit(id){editedIds.add(id);dirtyEdits=true;
 const b=document.getElementById("exportBtn");if(b)b.textContent="⬇ 导出源 ●";}
function addEdge(a,b){if(a===b||!byId[b])return false;
 const t=byId[b];
 if(t.prs.indexOf(a)>=0&&edges.some(e=>e.a===a&&e.b===b))return false;  // 已存在=幂等拒绝
 if(t.prs.indexOf(a)<0)t.prs.push(a);
 if(!edges.some(e=>e.a===a&&e.b===b))edges.push({a,b});
 markEdit(a);markEdit(b);return true;}
function delEdge(e){const i=edges.findIndex(x=>x.a===e.a&&x.b===e.b);if(i>=0)edges.splice(i,1);
 const t=byId[e.b];if(t){const j=t.prs.indexOf(e.a);if(j>=0)t.prs.splice(j,1);}
 markEdit(e.a);markEdit(e.b);selEdge=null;rebuildView();dirty=true;}
function setStatusAll(s){if(!selSet.size)return;
 selSet.forEach(id=>{const n=byId[id];if(n)n.status=s;});
 [...selSet].forEach(markEdit);rebuildView();hideCtx();dirty=true;}
function copySelIds(){navigator.clipboard&&navigator.clipboard.writeText([...selSet].join(","));
 hideCtx();}
function hideCtx(){document.getElementById("ctx").style.display="none";}
function showCtx(ev){const c=document.getElementById("ctx");let h="";
 if(selEdge)h+="<div class='ci' onclick='delEdgeSel()'>🗑 删除依赖 "+selEdge.a+" → "+selEdge.b+"</div>";
 const p=toWorld(ev),hit=nodeAt(p.x,p.y);
 const single=(hit&&hit.id)||(selSet.size===1?[...selSet][0]:null);
 if(single&&!selEdge){
  h+="<div class='ch'>"+single+" →</div>"
   +"<div class='ci' onclick=\"setStatusAll('进行中')\">▶ 进行中</div>"
   +"<div class='ci' onclick=\"setStatusAll('待验收')\">🔍 待验收</div>"
   +"<div class='ci' onclick=\"setStatusAll('完成')\">✓ 完成</div>"
   +"<div class='ci' onclick=\"setStatusAll('可开工')\">🚦 可开工</div>"
   +"<div class='ci' onclick=\"setStatusAll('阻塞')\">⏸ 阻塞</div>"
   +"<div class='ci' onclick=\"setStatusAll('冻结')\">❄ 冻结</div>"
   +"<div class='ci' onclick=\"setStatusAll('放弃')\">✕ 放弃</div>"
   +"<div class='ci' onclick=\"doRelease('"+single+"')\">🔓 释放认领</div>"
   +"<div class='ci' onclick='openTaskForm(\""+single+"\")'>✎ 编辑任务…</div>"
   +"<div class='ci' onclick='openTaskForm(null,\""+single+"\")'>✂ 拆解为子任务…</div>"
   +"<div class='ci' onclick='delTask(\""+single+"\")'>🗑 删除任务</div>"
   +"<div class='ci' onclick='copySelIds()'>📋 复制 id</div>";
 }else if(selSet.size>1&&!selEdge){
  h+="<div class='ch'>已选 "+selSet.size+" 个 → 批量状态：</div>";
  ["完成","待验收","进行中","可开工","阻塞","冻结","放弃"].forEach(s=>{
   h+="<div class='ci' onclick=\"setStatusAll('"+s+"')\">"+s+"</div>";});
  h+="<div class='ci' onclick='copySelIds()'>📋 复制所选 id</div>";
 }else if(!selEdge){
  h+="<div class='ci' onclick='openTaskForm()'>➕ 新建任务…</div>"+
     "<div class='ci' onclick='fitAll();hideCtx()'>⛶ 适配全图</div>"+
     "<div class='ci' onclick='relayout();hideCtx()'>⟲ 自动重排</div>";}
 c.innerHTML=h;c.style.display="block";
 c.style.left=Math.min(ev.clientX,innerWidth-190)+"px";
 c.style.top=Math.min(ev.clientY,innerHeight-28*c.querySelectorAll(".ci").length-20)+"px";}
function delEdgeSel(){if(selEdge)delEdge(selEdge);hideCtx();}
document.addEventListener("mousedown",ev=>{if(!ev.target.closest("#ctx"))hideCtx();},true);
cv.oncontextmenu=ev=>ev.preventDefault();
let lastRmb=null;  // 右键按下点：mouseup 会先清 drag，contextmenu 后到——用位移判断是否"右键无拖动"
cv.addEventListener("contextmenu",ev=>{
 if(lastRmb&&Math.hypot(ev.clientX-lastRmb.x,ev.clientY-lastRmb.y)<4)showCtx(ev);
 lastRmb=null;});
cv.onpointerdown=ev=>{if(flyRAF){cancelAnimationFrame(flyRAF);flyRAF=null;}const p=toWorld(ev);
 if(ev.button===1||ev.button===2||(ev.button===0&&spaceDown)){   // 平移三通道
  if(ev.button===2)lastRmb={x:ev.clientX,y:ev.clientY};
  drag={pan:true,sx:ev.clientX,sy:ev.clientY,ox:view.x,oy:view.y,rmb:ev.button===2};}
 else if(ev.button!==0){return;}
 else if(inMini(ev)){drag={mini:true};miniJump(ev);}
 else if(showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7){
  drag={divide:true,sx:ev.clientX,ox:divideX};}
 else{
  const port=portAt(p.x,p.y);                    // 输出端口热区：起连线
  if(port){drag={link:true,from:port.id,sx:ev.clientX,sy:ev.clientY,cx:ev.clientX,cy:ev.clientY};}
  else{
   const e0=(!nodeAt(p.x,p.y))?edgeAt(p.x,p.y):null; // 点边=选中边（Del 删除）
   if(e0){selEdge=e0;sel=null;selSet=new Set();dirty=true;}
   else{
    const n=nodeAt(p.x,p.y);
    if(n){
     if(ev.shiftKey){if(selSet.has(n.id)&&selSet.size>1)selSet.delete(n.id);else selSet.add(n.id);
      sel=n.id;showPanel(n);dirty=true;return;}
     sel=n.id;selEdge=null;if(!selSet.has(n.id))selSet=new Set([n.id]);
     showPanel(n);
     drag={n,dx:p.x-n.px,dy:p.y-n.py,sx:ev.clientX,sy:ev.clientY,moved:false,
      group:[...(n.isCluster?[n]:[...selSet])].filter(m=>m&&m.px!=null)
           .map(m=>({m,dx:p.x-m.px,dy:p.y-m.py}))};
    }else drag={box:true,sx:ev.clientX,sy:ev.clientY,cx:ev.clientX,cy:ev.clientY};
   }}}
 // 指针捕获：拖动中鼠标移出窗口/画布仍持续收到 move/up，杜绝"出界回来抽搐"
 try{cv.setPointerCapture(ev.pointerId);}catch(e2){}
 dirty=true;};
cv.addEventListener("pointermove",ev=>{if(!drag)return;
 if(drag.mini){miniJump(ev);return;}
 if(drag.divide){const dx=(ev.clientX-drag.sx)/view.k;divideX=drag.ox+dx;enforceDivide();dirty=true;return;}
 if(drag.box){drag.cx=ev.clientX;drag.cy=ev.clientY;dirty=true;return;}
 if(drag.link){drag.cx=ev.clientX;drag.cy=ev.clientY;dirty=true;return;}
 if(drag.moved===false&&Math.hypot(ev.clientX-drag.sx,ev.clientY-drag.sy)>4)drag.moved=true;
 if(drag.pan){view.x=drag.ox+ev.clientX-drag.sx;view.y=drag.oy+ev.clientY-drag.sy;}
 else if(drag.group){const p=toWorld(ev);       // 单/批量移动（簇卡片带动成员，各守分割墙）
  drag.group.forEach(g=>{let nx=p.x-g.dx,ny=p.y-g.dy;
   const doneSide=g.m.status==="完成";
   if(showDivide&&divideX!=null&&!g.m.isCluster){
    if(doneSide)nx=Math.min(nx,divideX-8-g.m.cw);else nx=Math.max(nx,divideX+8);}
   const dx=nx-g.m.px,dy=ny-g.m.py;
   g.m.px=nx;g.m.py=ny;
   if(g.m.isCluster){g.m.isCluster.members.forEach(id=>{const m=byId[id];m.px+=dx;m.py+=dy;});}
   else{g.m.x=nx;g.m.y=ny;}});
  computePorts();}  // 端口 y 是缓存值，拖动必须重算，否则贝塞尔垂直方向不跟随
 dirty=true;});
cv.addEventListener("pointerup",ev=>{
 if(drag&&drag.box){
  const x1=Math.min(drag.sx,drag.cx),x2=Math.max(drag.sx,drag.cx),
        y1=Math.min(drag.sy,drag.cy),y2=Math.max(drag.sy,drag.cy);
  if(x2-x1>6||y2-y1>6){
   const a={x:(x1-view.x)/view.k,y:(y1-view.y)/view.k},b={x:(x2-view.x)/view.k,y:(y2-view.y)/view.k};
   const hit=[];VN.forEach(n=>{if(!nodeVisible(n)||n.isCluster)return;
    if(n.px+n.cw>a.x&&n.px<b.x&&n.py+n.ch>a.y&&n.py<b.y)hit.push(n.id);});
   selSet=new Set(hit);sel=hit[0]||null;selEdge=null;
   if(sel)showPanel(byId[sel]);else document.getElementById("inspector").innerHTML="<div class='ph'>框选 "+selSet.size+" 个任务</div>";
  }else{sel=null;selSet=new Set();selEdge=null;hi=null;
   document.getElementById("inspector").innerHTML="<div class='ph'>点选任务查看详情</div>";}
 }else if(drag&&drag.link){
  const p=toWorld(ev),t=nodeAt(p.x,p.y);
  if(t&&t.id!==drag.from&&addEdge(drag.from,t.id)){rebuildView();showPanel(t);}
 }else if(drag&&drag.n&&drag.n.isCluster&&!drag.moved){
  folded[drag.n.isCluster.id]=!folded[drag.n.isCluster.id];rebuildView();}
 try{cv.releasePointerCapture(ev.pointerId);}catch(e2){}
 drag=null;dirty=true;});
cv.onpointerleave=ev=>{if(!drag){hi=null;dirty=true;}};
cv.addEventListener("pointermove",ev=>{if(drag)return;const p=toWorld(ev);
 divideHover=showDivide&&divideX!=null&&Math.abs(ev.clientX-(divideX*view.k+view.x))<7;
 const n=nodeAt(p.x,p.y),po=portAt(p.x,p.y),ed=n?null:edgeAt(p.x,p.y);
 hover=n?n.id:null;hi=n?n.id:null;
 cv.style.cursor=divideHover?"col-resize":(po?"crosshair":(n?"grab":(ed?"pointer":(spaceDown?"grab":"crosshair"))));
 dirty=true;});
cv.onpointerleave=ev2=>{if(!drag&&!sel){hi=null;dirty=true;}};
cv.ondblclick=ev=>{const p=toWorld(ev);const n=nodeAt(p.x,p.y);
 if(n){sel=n.id;selSet=new Set([n.id]);showPanel(n);flyTo(n.px+n.cw/2,n.py+n.ch/2,1.15);}
 else fitAll();};
cv.onwheel=ev=>{ev.preventDefault();const f=ev.deltaY<0?1.13:0.885;const r=toWorld(ev);
 view.k=Math.min(2.5,Math.max(0.2,view.k*f));
 view.x=ev.clientX-r.x*view.k;view.y=ev.clientY-r.y*view.k;dirty=true;};
