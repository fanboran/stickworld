function sideW(){const l=document.getElementById("sideL"),r=document.getElementById("sideR");
 return{L:(l&&l.style.display!=="none")?(l.offsetWidth||248):0,R:(r&&r.style.display!=="none")?(r.offsetWidth||308):0};}
let flyRAF=null;
function flyTo(wx,wy,k){ // 特写镜头：缓动飞向目标（侧栏避让后的可视中心）
 const s=sideW();k=k||view.k;
 const tx=s.L+(VW-s.L-s.R)/2-wx*k,ty=Math.max(BAR_H,VH/2-wy*k);
 const f={x:view.x,y:view.y,k:view.k},st=performance.now(),dur=460;
 if(flyRAF)cancelAnimationFrame(flyRAF);
 const step=ts=>{const u=Math.min(1,(ts-st)/dur),e=u<.5?2*u*u:1-Math.pow(-2*u+2,2)/2;
  view.x=f.x+(tx-f.x)*e;view.y=f.y+(ty-f.y)*e;view.k=f.k+(k-f.k)*e;dirty=true;
  if(u<1)flyRAF=requestAnimationFrame(step);};
 flyRAF=requestAnimationFrame(step);}
function centerOn(wx,wy,k){const s=sideW();if(k)view.k=k;
 view.x=s.L+(VW-s.L-s.R)/2-wx*view.k;view.y=Math.max(BAR_H,VH/2-wy*view.k);dirty=true;}
function fitAll(){const g=graphBBox();const s=sideW();
 view.k=Math.min((VW-s.L-s.R-30)/g.w,(VH-BAR_H-40)/g.h,1.2);
 view.x=s.L+(VW-s.L-s.R-g.w*view.k)/2-g.minX*view.k;
 view.y=Math.max(BAR_H,(VH-g.h*view.k)/2)-g.minY*view.k;dirty=true;}
function locateActive(){const act=VN.filter(n=>ACTIVE.has(n.status)||n.status==="可开工");
 const t=act.length?act:VN;
 const xs=t.map(n=>n.px+n.cw/2),ys=t.map(n=>n.py+n.ch/2);
 centerOn((Math.min(...xs)+Math.max(...xs))/2,(Math.min(...ys)+Math.max(...ys))/2,1);}
function relayout(){focusLane=null;focusLines=null;VN.forEach(n=>{if(!n.isCluster){n.x=null;n.y=null;}});
 divideX=null;laneBandLayout();rebuildView();fitAll();dirty=true;}
let focusLane=null,focusLines=null,focusSnapshot=null;  // 快照：进入聚拢前的各节点坐标，退出时恢复（手动布局不丢）
function applyFocus(){
 if(!focusLane){initDivide();rebuildView();locateActive();dirty=true;return;}  // 防呆分支：不走 relayout（会清手动布局）
 const vis=n=>!laneHidden(n.lane);  // 被隐藏的线不参与聚拢布局（显隐与聚拢正交）
 const inS=VN.filter(n=>n.lane===focusLane&&vis(n));
 const inIds=new Set(inS.map(n=>n.id));
 const isPre=n=>VE.some(e=>e.a===n.id&&inIds.has(e.b));
 const isBlk=n=>VE.some(e=>e.b===n.id&&inIds.has(e.a));
 const extP=VN.filter(n=>!n.isCluster&&vis(n)&&!inIds.has(n.id)&&isPre(n)&&!isBlk(n));
 const extB=VN.filter(n=>!n.isCluster&&vis(n)&&!inIds.has(n.id)&&isBlk(n)&&!isPre(n));
 const both=VN.filter(n=>!n.isCluster&&vis(n)&&!inIds.has(n.id)&&isPre(n)&&isBlk(n));
 const others=VN.filter(n=>!n.isCluster&&vis(n)&&n!==null&&!inIds.has(n.id)&&!extP.includes(n)&&!extB.includes(n)&&!both.includes(n));
 const clus=VN.filter(n=>n.isCluster);
 VN.forEach(n=>n._f="other");
 inS.forEach(n=>n._f="core");extP.forEach(n=>n._f="pre");
 extB.forEach(n=>n._f="post");both.forEach(n=>n._f="both");clus.forEach(n=>n._f="other");
 const pRight=extP.length?Math.max(...extP.map(n=>n.px+n.cw)):30;
 layoutSub(extP,30);
 layoutSub(inS,pRight+110);
 layoutSub(both,(inS.length?Math.max(...inS.map(n=>n.px+n.cw)):pRight)+110);
 layoutSub(extB,(both.length?Math.max(...both.map(n=>n.px+n.cw)):inS.length?Math.max(...inS.map(n=>n.px+n.cw)):pRight)+110);
 layoutSub(clus.concat(others),(extB.length?Math.max(...extB.map(n=>n.px+n.cw)):0)+160);
 focusLines=null;
 if(inS.length&&extP.length)focusLines={pre:(Math.max(...extP.map(n=>n.px+n.cw))+Math.min(...inS.map(n=>n.px)))/2};
 if(extB.length)focusLines={...focusLines,post:(Math.max(...inS.map(n=>n.px+n.cw))+Math.min(...extB.map(n=>n.px)))/2};
 computePorts();dirty=true;}
function docHref(p){return "../"+String(p).replace(/^docs\//,"");}
function showPanel(n){const p=document.getElementById("inspector");
 const chip=(id)=>{const t=byId[id];return"<span class='tag' onclick='jump(\""+id+"\")'>"+(t?t.name:id)+" · "+(t?t.status:"?")+"</span>";};
 const inReady=READY.indexOf(n.id),inCrit=CRIT.indexOf(n.id);
 const ctxBits=["前置 "+((n.prs||[]).length),"被依赖 "+(blocksOf[n.id].length)];
 if(inReady>=0)ctxBits.push("🚦 就绪中");
 if(inCrit>0)ctxBits.push("🛤 关键路径第 "+(inCrit+1)+" 跳");
 if(n.kind==="里程碑")ctxBits.push("收口门");
 p.innerHTML="<h3>"+(n.kind==="里程碑"?"◆ ":"")+n.name+"</h3>"
 +"<div class='ctxrow'>"+ctxBits.map(function(x){return "<span"+(x.indexOf("🛤")>=0?" style='color:var(--amber)'":"")+">"+x+"</span>";}).join(" · ")
 +"　<span style='cursor:pointer;color:#79b8ff' title='相关项小窗：前置/被依赖迷你卡' onclick='relPopup(this.dataset.t)' data-t='"+n.id+"'>⧉ 浮窗</span></div>"
 +"<div style='margin:6px 14px 0'><span class='tag' style='cursor:default;color:"+COL[n.status]+"'>"+n.status+"</span>"
 +(n.lane?"<span class='tag' style='cursor:default'>"+n.lane+"</span>":"")
 +(n.tree?"<span class='tag' style='cursor:default'>⌂ "+n.tree+"</span>":"")
 +(n.claim?"<span class='tag' style='cursor:default;color:var(--amber)'>◉ 认领者 "+n.claim+"</span>":"")+"</div>"
 +(selSet.size>1?"<div class='row'>已框选 "+selSet.size+" 个（拖动批量移动 / 右键批量改状态）</div>":"")
 +(n.domain&&n.domain.length?"<div class='row'>文件域："+n.domain.join(", ")+"</div>":"")
 +(n.doc?"<div class='row'>📄 <a style='color:#79b8ff' href='"+docHref(n.doc)+"'>"+n.doc+"</a></div>":"")
 +(n.prs&&n.prs.length?"<div class='row'>前置（点击跳转）：<br>"+n.prs.map(chip).join("")+"</div>":"")
 +(blocksOf[n.id].length?"<div class='row'>被依赖：<br>"+blocksOf[n.id].map(chip).join("")+"</div>":"")
 +(n.note?"<div class='row' style='color:#c3cdd8'>"+n.note+"</div>":"")
 +(n.exempt?"<div class='row' style='color:var(--amber)'>⚠ 豁免派活校验（见注）</div>":"")
 +"<div class='row' style='color:#55677f;font:600 10px var(--mono)'>"+n.id+"</div>";
 if(curView!=="producer")document.getElementById("sideR").style.display="flex";}
function jump(id){const cid=memberOf[id];if(cid&&folded[cid]){folded[cid]=false;rebuildView();}
 const n=byId[id];if(!n)return;sel=id;selSet=new Set([id]);selEdge=null;
 showPanel(n);flyTo(n.px+n.cw/2,n.py+n.ch/2,1.05);}
// ── 交互（对标 Shader Graph / ComfyUI：左键框选，中键/右键/空格+左键平移，端口连线建边） ──
