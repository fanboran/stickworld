function inMini(ev){const r=mini.getBoundingClientRect();
 return ev.clientX>=r.left&&ev.clientX<=r.right&&ev.clientY>=r.top&&ev.clientY<=r.bottom;}
function miniJump(ev){if(!mini._map)return;const{g,s,ox,oy}=mini._map;const r=mini.getBoundingClientRect();
 const wx=(ev.clientX-r.left-ox)/s+g.minX,wy=(ev.clientY-r.top-oy)/s+g.minY;
 view.x=VW/2-wx*view.k;view.y=VH/2-wy*view.k;dirty=true;}
// ── 工具栏 ──
document.getElementById("legend").innerHTML=STATUS.map(s=>"<span><span class='sw' style='background:"+COL[s]+"'></span>"+s+"</span>").join("");
const lanesBox=document.getElementById("lanes");
lanes.forEach((l,i)=>{const c=document.createElement("span");c.className="lchip";
 c.innerHTML='<span class="sw" style="background:'+LANE_COL[i%LANE_COL.length]+'"></span>'+l;
 c.title="单击=聚拢该线居中（再点退出，显隐/布局状态保留） · Alt+单击=显隐该线";
 c.onclick=ev=>{
  if(ev.altKey){laneVis[l]=!laneVis[l];c.classList.toggle("off",!laneVis[l]);dirty=true;return;}
  if(focusLane===l){  // 退出聚拢：恢复进入前坐标与分割墙，不清手动布局
   focusLane=null;c.classList.remove("focus");
   if(focusSnapshot){focusSnapshot.forEach(a=>{a[0].px=a[1];a[0].py=a[2];});focusSnapshot=null;}
   initDivide();rebuildView();fitAll();}
  else{  // 进入聚拢：快照坐标 → 墙互斥 → 分区布局
   lanesBox.querySelectorAll(".lchip.focus").forEach(x=>x.classList.remove("focus"));
   focusLane=l;focusLines=null;c.classList.add("focus");
   focusSnapshot=nodes.map(n=>[n,n.px,n.py]);
   divideX=null;rebuildView();applyFocus();fitAll();}
  dirty=true;};
 lanesBox.appendChild(c);});
const chk=DATA.check||{errors:[],warns:[]};
const chipEl=document.getElementById("checkChip");
chipEl.textContent=chk.errors.length?("✗ "+chk.errors.length+" 错误"+(chk.warns.length?" · "+chk.warns.length+" 警告":""))
 :(chk.warns.length?("⚠ 通过 · "+chk.warns.length+" 警告"):"✓ 校验通过");
chipEl.style.background=chk.errors.length?"#4a1526":(chk.warns.length?"#3a2c0e":"#123a2a");
chipEl.style.color=chk.errors.length?"#ffc9d6":(chk.warns.length?"#ffe08a":"#b8f5da");
chipEl.style.borderColor=chk.errors.length?"#6b2436":(chk.warns.length?"#6b5312":"#1d5340");
chipEl.onclick=toggleMsgs;
// ── 调度视角开关：就绪集高亮 / 关键路径高亮 ──
const READY=DATA.ready||[],CRIT=DATA.crit||[];
let readyOnly=false,critOnly=false;
const rchip=document.getElementById("readyChip");
rchip.textContent="🚦 可派 "+READY.length;
rchip.style.color=READY.length?"#a5f3fc":"#94a3b8";
rchip.style.background=READY.length?"#0c2a33":"#111a29";
const cchip=document.getElementById("critChip");
cchip.textContent="🛤 关键路径 "+Math.max(0,CRIT.length-1)+" 跳";
cchip.style.color=CRIT.length?"#ffe08a":"#94a3b8";
cchip.style.background=CRIT.length?"#3a2c0e":"#111a29";
function refreshChips(){rchip.style.borderColor=readyOnly?"#22d3ee":"#1d2a3d";
 cchip.style.borderColor=critOnly?"#fbbf24":"#1d2a3d";}
rchip.onclick=()=>{readyOnly=!readyOnly;critOnly=false;refreshChips();dirty=true;};
cchip.onclick=()=>{critOnly=!critOnly;readyOnly=false;refreshChips();dirty=true;};
function toggleMsgs(){const m=document.getElementById("msgs");
 if(m.style.display==="block"){m.style.display="none";return;}
 m.innerHTML=(chk.errors.length?chk.errors.map(e=>"<div class='e'>"+e+"</div>").join(""):"<div class='e' style='opacity:.6'>无 ERROR</div>")
 +chk.warns.map(w=>"<div class='w'>"+w+"</div>").join("");
 m.style.display="block";}
document.getElementById("help").onclick=ev=>{if(ev.target.id==="help")ev.currentTarget.style.display="none";};
const searchBox=document.getElementById("search");
searchBox.oninput=()=>{q=searchBox.value.trim();applySearch();dirty=true;};
searchBox.onkeydown=ev=>{if(ev.key==="Enter"){const hit=nodes.find(n=>n._hit);if(hit)jump(hit.id);}
 if(ev.key==="Escape"){searchBox.value="";q="";applySearch();dirty=true;}};
function applySearch(){if(!q){nodes.forEach(n=>n._hit=false);return;}
 const lower=q.toLowerCase();
 nodes.forEach(n=>n._hit=(n.id+" "+n.name+" "+n.note).toLowerCase().includes(lower));}
addEventListener("keydown",ev=>{
 const inField=document.activeElement===searchBox||/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
 if(ev.code==="Space"&&!inField){spaceDown=true;cv.style.cursor="grab";ev.preventDefault();return;}
 if(ev.key==="Escape"){if(document.getElementById("ctx").style.display==="block"){hideCtx();return;}
  if(document.getElementById("modal").style.display==="flex"){closeModal();return;}
  sel=null;selSet=new Set();selEdge=null;hi=null;
  document.getElementById("inspector").innerHTML="<div class='ph'>点选任务查看详情</div>";dirty=true;return;}
 if(inField)return;
 if((ev.key==="Delete"||ev.key==="Backspace")&&selEdge){delEdge(selEdge);return;}
 // 工业软件快捷键组（大写锁定不敏感）
 const k=ev.key.toLowerCase();
 if(k==="n"){openTaskForm();return;}
 if(k==="f"){fitAll();return;}
 if(k==="t"){toggleTower();return;}
 if(k==="g"){applyLayout(0);return;}
 if(k==="l"){locateActive();return;}
 if(k==="d"){toggleDock();return;}
 if(k==="c"){critOnly=!critOnly;refreshChips();dirty=true;return;}
 if(k==="r"){readyOnly=!readyOnly;critOnly=false;refreshChips();dirty=true;return;}
 const vi=parseInt(ev.key);
 if(vi>=1&&vi<=6){const vs=["graph","producer","eng","design","art","qa"];setView(vs[vi-1]);}});
addEventListener("keyup",ev=>{if(ev.code==="Space"){spaceDown=false;cv.style.cursor="default";dirty=true;}});
// ── 岗位视图体系（同一份 DAG 的不同投影；hash 路由 #view=xxx 可直达/分享） ──
const VIEWS={
 graph:{},
 producer:{},
 eng:{lanes:new Set(["复刻主线","UI线","配置存档","战略图","地图系统","经济循环","玩法系统","工程债","里程碑"])},
 design:{lanes:new Set(["叙事设计","决策","玩法系统","经济循环","里程碑"])},
 art:{ids:n=>/^(asset_|ext_art|fx_|p12_skins)/.test(n.id)||n.lane==="美术"},
 qa:{ids:n=>/^(debt_|test_|ci_|arena_)/.test(n.id)||n.status==="待验收"||/^(demo_|hp_default_zero)/.test(n.id)}
};
let curView=null,viewSnapshot=null;  // 初始 null：启动 setView 必须完整跑一遍 UI 初始化（幂等守卫只拦重复调用）
function setView(v,force){const prev=curView;
 if(!VIEWS[v])v="graph";                       // hash 手输未知视图 → 回退全图
 if(prev===v&&!force)return;                   // 同页签幂等：二次快照会把投影态当原始态
 curView=v;
 if(location.hash!=="#view="+v)location.hash="#view="+v;
 document.querySelectorAll(".vtab").forEach(t=>t.classList.toggle("on",t.dataset.v===v));
 viewFilter=VIEWS[v]||{};
 const dash=document.getElementById("dash"),showDash=v==="producer";
 dash.style.display=showDash?"block":"none";
 ["cv","mini","cfoot"].forEach(id2=>{const el=document.getElementById(id2);if(el)el.style.visibility=showDash?"hidden":"visible";});
 document.getElementById("sideL").style.display=showDash?"none":"flex";
 document.getElementById("sideR").style.display=showDash?"none":"flex";
 const vbel=document.getElementById("vbar");
 vbel.style.display=showDash?"none":"flex";
 if(!showDash){const sw=sideW();vbel.style.top=BAR_H+"px";vbel.style.left=sw.L+"px";vbel.style.right=sw.R+"px";buildVbar();}
 const dkel=document.getElementById("dock");
 dkel.style.display=showDash?"none":"flex";
 if(showDash){dash.style.top=BAR_H+"px";buildDash();return;}
 // 岗位视图 = 布局投影：进入时快照全图坐标 → 对可见子集重新 dagre（隐藏节点不再占位）→ 退出恢复
 // 切视图前清聚拢/关键路径残留：focusLane 的 _f 淡出标记会污染新视图
 focusLane=null;focusLines=null;critOnly=false;refreshChips();
 VN.forEach(n=>{delete n._f;});
 if(prev!==v&&viewSnapshot){viewSnapshot.forEach(a=>{a[0].px=a[1];a[0].py=a[2];});viewSnapshot=null;}
 if(v!=="graph"){viewSnapshot=nodes.map(n=>[n,n.px,n.py]);}
 rebuildView();
 if(v!=="graph"){dagreLayout();rebuildView();fitAll();}
 else{locateActive();}
 buildSide(v);
 dirty=true;}
function jumpTo(id){setView("graph");jump(id);}
function buildVbar(){const v=document.getElementById("vbar");let h="";
 h+="<span class='lbl'>布局</span><span class='vg'>"
  +"<button class='vt on' onclick='applyLayout(0)'>▦ 泳道带</button>"
  +"<button class='vt' onclick='applyLayout(1)'>⟲ 交叉最小</button></span><span class='sep'></span>";
 h+="<span class='lbl'>状态</span><span class='vg'>"
  +STATUS.map(function(st){return "<button class='vt"+(statusFilter.has(st)?" on":"")+"' style='border-left:3px solid "+COL[st]+"' onclick=\"toggleStatus('"+st+"')\">"+st+"</button>";}).join("")
  +"</span><span class='sep'></span>";
 h+="<span class='vg'>"
  +"<button class='vt"+(microOn?" on":"")+"' onclick='microOn=!microOn;refilter()'>◌ 微任务</button>"
  +"<button class='vt"+(doneOn?" on":"")+"' onclick='doneOn=!doneOn;refilter()'>✓ 完成区</button>"
  +"</span><span class='sep'></span>";
 h+="<span class='vg'>"
  +"<button class='vt' onclick='view.k=Math.min(2.5,view.k*1.25);dirty=true'>＋</button>"
  +"<button class='vt' onclick='view.k=Math.max(0.2,view.k/1.25);dirty=true'>－</button>"
  +"<button class='vt' onclick='fitAll()'>⤢ 适配</button>"
  +"<button class='vt' onclick='locateActive()'>⌖ 活跃面</button>"
  +"</span><span class='sep'></span><span class='lbl'>数据源</span><span class='vg' id='srcSwitch2'>"
  +"<button class='vt on' onclick=\"setGanttSource('all')\">全部</button>"
  +"<button class='vt' onclick=\"setGanttSource('real')\">真实</button>"
  +"<button class='vt' onclick=\"setGanttSource('sim')\">SIM</button></span>";
 h+="<span class='vg'><button class='vt"+(towerMode?" on":"")+"' id='towerBtn' onclick='toggleTower()' title='塔台巡航：镜头自动轮巡全部已认领任务（机场调度监控模式）'>✈ 塔台巡航</button></span>";
 v.innerHTML=h;}

// ── 塔台巡航：镜头自动轮巡已认领任务（机场调度监控模式） ──
let towerMode=false,towerRAF=null,towerIdx=0,towerLast=0;
function toggleTower(){towerMode=!towerMode;
 const b=document.getElementById("towerBtn");if(b)b.classList.toggle("on",towerMode);
 if(towerRAF){cancelAnimationFrame(towerRAF);towerRAF=null;}
 if(!towerMode)return;
 const step=ts=>{ // 3.2s/站：flyTo 下一认领任务
  if(!towerMode){towerRAF=null;return;}
  if(ts-towerLast>3200){towerLast=ts;
   const claimed=nodes.filter(n=>n.claim&&n.status!=="完成");
   if(claimed.length){const n=claimed[towerIdx%claimed.length];towerIdx++;
    hi=n.id;sel=n.id;selSet=new Set([n.id]);showPanel(n);relPopup(n.id);
    flyTo(n.px+n.cw/2,n.py+n.ch/2,1.0);}
   else{towerMode=false;const b2=document.getElementById("towerBtn");if(b2)b2.classList.remove("on");}}
  towerRAF=requestAnimationFrame(step);};
 towerLast=0;towerRAF=requestAnimationFrame(step);}
function applyLayout(mode){ // 0=泳道带状 1=dagre 交叉最小化
 if(curView==="graph"){laneBandLayout();}else{dagreLayout();}
 rebuildView();fitAll();dirty=true;}
function toggleStatus(st){statusFilter.has(st)?statusFilter.delete(st):statusFilter.add(st);
 buildVbar();refilter();}
function refilter(){rebuildView();
 if(curView==="graph"){laneBandLayout();}else{dagreLayout();}
 rebuildView();fitAll();dirty=true;}
function sideSelect(id){const n=byId[id];if(!n)return;
 sel=id;selSet=new Set([id]);selEdge=null;hi=id;showPanel(n);
 flyTo(n.px+n.cw/2,n.py+n.ch/2,Math.max(view.k,0.85));  // 特写：相机平移聚焦到该项
 dirty=true;}
// ── 相关项浮窗（左下小窗：中心任务+前置列+被依赖列迷你卡） ──
function relPopup(id){const n=byId[id];if(!n)return;
 const mrow=t=>"<div class='lst' onclick='sideSelect(\""+t.id+"\")'>"
  +"<span class='dot' style='background:"+(COL[t.status]||"#888")+"'></span>"
  +"<span class='lid'>"+t.id+"</span><span class='lname'>"+t.name+"</span>"
  +"<span class='lgo' onclick='event.stopPropagation();jumpTo(\""+t.id+"\")'>⤢</span></div>";
 let h="<div class='phead'><b>"+(n.kind==="里程碑"?"◆ ":"")+esc(n.name)+"</b>"
  +"<span style='margin-left:auto;cursor:pointer;color:var(--dim2)' onclick='closeRel()'>✕</span></div>"
  +"<div class='pbody'>";
 h+="<div class='pane-head' style='position:static'>前置 "+(n.prs||[]).length+"</div>";
 h+=n.prs&&n.prs.length?n.prs.map(p=>byId[p]?mrow(byId[p]):"").join(""):"<div class='ph'>无</div>";
 h+="<div class='pane-head' style='position:static'>被依赖 "+(blocksOf[n.id]||[]).length+"</div>";
 h+=blocksOf[n.id].length?blocksOf[n.id].map(p=>byId[p]?mrow(byId[p]):"").join(""):"<div class='ph'>无</div>";
 h+="</div>";
 const w=document.getElementById("relwin");
 w.innerHTML=h;w.style.display="flex";}
function closeRel(){document.getElementById("relwin").style.display="none";}
function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/"/g,"&quot;").replace(/</g,"&lt;");}
function sideRow(n){return"<div class='lst"+(n.status==="进行中"?" active":"")+"' onclick='sideSelect(\""+n.id+"\")' title=\""+esc(n.name)+"（点击详情，⤢ 跳全图）\">"
 +"<span class='dot' style='background:"+(COL[n.status]||"#888")+"'></span>"
 +"<span class='lid'>"+n.id+"</span><span class='lname'>"+n.name+"</span>"
 +"<span class='lgo' title='跳全图定位' onclick='event.stopPropagation();jumpTo(\""+n.id+"\")'>⤢</span></div>";}
function sideHead(t,hint){return"<div class='pane-head'>"+t+(hint?"<span class='hint'>"+hint+"</span>":"")+"</div>";}
function gateProgress(gid,label){ // 收口门进度内嵌（点击展开成员清单）
 const g=byId[gid];if(!g)return"";
 const ds=blocksOf[gid]||[],done=ds.filter(d=>byId[d]&&byId[d].status==="完成").length;
 const pct=ds.length?Math.round(100*done/ds.length):0;
 let h="<div class='grow' onclick='toggleGate(\""+gid+"\")' title='点击展开/收起成员'>"
  +"<span class='nm' style='color:#eaf6ff'>◆ "+(label||g.name)+"</span>"
  +"<span class='gbar'><i style='width:"+pct+"%'></i></span><span class='pc'>"+done+"/"+ds.length+"</span></div>";
 if(window["_g_"+gid]){
  h+="<div style='max-height:200px;overflow:auto'>";
  ds.forEach(d=>{if(byId[d])h+=sideRow(byId[d]);});
  h+="</div>";}
 return h;}
function toggleGate(gid){window["_g_"+gid]=!window["_g_"+gid];buildSide(curView);}
function buildSide(v){const L=document.getElementById("sideL");let h="";
 const live=n=>n.status!=="完成"&&n.status!=="放弃";
 const active=nodes.filter(n=>n.status==="进行中"||n.status==="待验收");
 const ready=nodes.filter(n=>live(n)&&n.status!=="冻结"
  &&(n.prs||[]).every(p=>p===n.id||(byId[p]&&byId[p].status==="完成")));
 // 顶部 kv 状态条（LOGIC-8 status-strip：六格等宽）
 const nDone=nodes.filter(n=>n.status==="完成").length,
       nAct=nodes.filter(n=>n.status==="进行中"||n.status==="待验收").length,
       nReady=ready.length,
       nBlk=nodes.filter(n=>n.status==="阻塞").length,
       nFrz=nodes.filter(n=>n.status==="冻结").length;
 h+="<div class='strip'>"
  +[["任务",nodes.length,""],["完成",nDone,"g"],["进行",nAct,"c"],["就绪",nReady,"g"],["阻塞",nBlk,"y"],["冻结",nFrz,""]]
   .map(x=>"<div class='kv'><span>"+x[0]+"</span><b class='"+x[2]+"'>"+x[1]+"</b></div>").join("")
  +"</div>";
 if(v==="eng"){
  h+=sideHead("⚙ 进行中 / 待验收","代码线");
  h+=active.filter(n=>n.lane!=="宣发运营").map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🚦 就绪可派","前置全齐");
  h+=ready.filter(n=>n.lane!=="叙事设计"&&n.lane!=="决策"&&n.lane!=="宣发运营").map(sideRow).join("")||"<div class='ph'>无</div>";
  const dom={};active.forEach(n=>(n.domain||[]).forEach(d=>{if(d)dom[d]=n.id;}));
  h+=sideHead("⚡ 文件域占用","并行写必冲突");
  h+=Object.keys(dom).map(d=>"<div class='lst grp' title='进行中任务正占用此域'><span></span><span class='lid' style='overflow:visible'>"+d+"</span><span class='lname' style='text-align:right'>"+dom[d]+"</span><span></span></div>").join("");
 }else if(v==="design"){
  const dec=nodes.filter(n=>/^dec_/.test(n.id)&&live(n));
  h+=sideHead("🏛 等创始人拍板","零代码成本·解锁下游");
  h+=dec.map(n=>sideRow(n)).join("")||"<div class='ph'>无待决策项</div>";
  h+=sideHead("📐 设计产出清单","叙事/玩法/经济设计");
  h+=nodes.filter(n=>n.lane==="叙事设计"&&live(n)).map(sideRow).join("")
   +nodes.filter(n=>n.lane==="玩法系统"&&/^(content_|autonomy_|idle_|god_view)/.test(n.id)&&live(n)).map(sideRow).join("");
 }else if(v==="art"){
  const ext=byId.ext_art;
  h+=sideHead("📡 外部资产通道","采购/自制交付状态");
  h+="<div class='extStrip'><b>ext_art 外部美术资产通道</b><br>状态：<span class='st'>"+ext.status.toUpperCase()+"</span> —— 等待外部交付（手绘贴图/音效采购）。<br>下方 P1~P7 素材替换全部挂此通道：通道不开，资产任务只能做程序侧准备。需求单=待办 PLACEHOLDER 表。</div>";
  h+=sideHead("🎨 素材替换清单","点击行看详情");
  h+=nodes.filter(n=>/^(asset_p|fx_directional|fx_explosion|fx_ground|fx_rain|p12_skins)/.test(n.id)).sort((a,b)=>a.id.localeCompare(b.id)).map(sideRow).join("");
  h+=sideHead("🧰 程序侧配套","材质/粒子管线");
  h+=nodes.filter(n=>/^(texture_gen_regression|weather_env|behavior_)/.test(n.id)||n.id==="p3_thatch").map(sideRow).join("");
 }else if(v==="qa"){
  h+=sideHead("🐞 缺陷清单","观察场验收遗留");
  h+=nodes.filter(n=>/^debt_/.test(n.id)).map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🔍 待验收","需人工/游戏内确认");
  h+=active.filter(n=>n.status==="待验收").map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🧰 测试基建","稳定性/CI");
  h+=nodes.filter(n=>/^(test_stability|ci_enable|texture_gen_regression)/.test(n.id)).map(sideRow).join("");
  h+=sideHead("◆ Demo 收口进度","点击展开成员");
  h+=gateProgress("demo_content","Demo 内容收口")+gateProgress("demo_release","Demo 发布");
 }else{ // graph 全图
  h+=sideHead("🚦 就绪集 top","前置全齐可派活");
  h+=ready.slice(0,14).map(sideRow).join("")||"<div class='ph'>无</div>";
  h+=sideHead("🗂 泳道","任务数");
  const cnt={};nodes.forEach(n=>{if(live(n))cnt[n.lane]=(cnt[n.lane]||0)+1;});
  h+=Object.keys(cnt).map(l=>"<div class='lst grp'><span></span><span class='lname'>"+l+"</span><span class='cnt'>"+cnt[l]+"</span><span></span></div>").join("");
  h+=sideHead("ℹ 操作","常用");
  h+="<div class='ph'>左键拖空白=框选 · 中/右键/空格+拖=平移<br>右缘拖线=建依赖 · 右键=批量/编辑<br>🛤 关键路径=琥珀蚂蚁线 · Alt+点泳道=显隐</div>";
 }
 L.innerHTML=h;L.style.top=BAR_H+"px";
 document.getElementById("sideR").style.top=BAR_H+"px";}
function buildDash(){const P=DATA.producer||{},d=document.getElementById("dash");const LIMIT=6;
 const liveReady=nodes.filter(n=>n.status!=="完成"&&n.status!=="冻结"&&n.status!=="放弃"
  &&(n.prs||[]).every(p=>p===n.id||(byId[p]&&byId[p].status==="完成")));
 const S=Object.assign({},P.stats||{},{ready:liveReady.length});
 const tch=(n,extra)=>"<span class='tchip' onclick='jumpTo(\""+n.id+"\")'>"
  +"<span class='dot' style='background:"+(COL[n.status]||"#888")+"'></span>"+n.name
  +(extra||"")+"</span>";
  let h="<div class='strip'>"
  +[["任务总数",S.nodes,""],["已完成",S.done,"g"],["进行/待验收",S.active,"c"],
    ["就绪可派",S.ready,"g"],["阻塞",S.blocked,"y"],["冻结",S.frozen,""]]
   .map(x=>"<div class='kv'><span>"+x[0]+"</span><b class='"+x[2]+"'>"+x[1]+"</b></div>").join("")
  +"</div><div class='layout'><div class='col' id='dashL'></div><div class='col' id='dashR'></div>";
 const L=[],R=[];
 if((P.combo||[]).length)L.push("<div class='card'><h4>🚦 建议派活组合（域互斥 ≤"+LIMIT+" 线）</h4>"
  +P.combo.map(id=>byId[id]?tch(byId[id]," <span style='color:#6e7a87'>"+byId[id].lane+"</span>"):"").join("")+"</div>");
 if((P.crit||[]).length)L.push("<div class='card'><h4>🛤 关键路径（"+(P.crit.length-1)+" 跳）</h4><div style='line-height:2.1'>"
  +P.crit.map((id,i)=>byId[id]?(i?"<span style='color:#6e7a87'> → </span>":"")+tch(byId[id]):"").join("")+"</div>"
  +"<div class='hint' style='margin:6px 14px 0'>压缩关键路径靠拆依赖/拆任务/外购前置；加并发只能压非关键路径</div></div>");
 const byLane={};liveReady.forEach(n=>{(byLane[n.lane||"（无线）"]=byLane[n.lane||"（无线）"]||[]).push(n);});
 L.push("<div class='card'><h4>📦 就绪集 "+liveReady.length+" 个（点击行在图上定位）</h4><div style='max-height:340px;overflow:auto'>");
 Object.keys(byLane).sort().forEach(ln=>{L.push("<div class='laneHead'>"+ln+" · "+byLane[ln].length+"</div>"
  +byLane[ln].map(n=>tch(n)).join(""));});
 L.push("</div></div>");
 if((P.gates||[]).length)R.push("<div class='card'><h4>◆ 里程碑燃尽</h4>"
  +P.gates.map(g=>"<div class='gate'><span class='nm' onclick='jumpTo(\""+g.id+"\")' title='"+g.id+"'>"+g.name
   +"</span><span class='bar'><i style='width:"+(g.total?Math.round(100*g.done/g.total):0)+"%'></i></span><span class='pc'>"
   +g.done+"/"+g.total+"</span></div>").join("")+"</div>");
 // 👥 AI 负载（真实认领=字段 + 调度日志统计）
 const claimedNow=nodes.filter(n=>n.claim&&n.status!=="完成");
 const byAg={};
 (DATA.simlog&&DATA.simlog.events||[]).forEach(e=>{
  if(!e.agent||e.agent==="unknown")return;
  byAg[e.agent]=byAg[e.agent]||{done:0,claims:0};
  if(e.action==="done")byAg[e.agent].done++;
  if(e.action==="claim")byAg[e.agent].claims++;
 });
 let agCard="<div class='card'><h4>👥 AI 负载（谁在做什么）</h4>";
 agCard+="<div class='laneHead' style='margin:4px 14px 2px'>◉ 认领中（真实认领）</div>";
 agCard+=claimedNow.length?claimedNow.map(n=>tch(n," <span style='color:var(--amber)'>◉ "+n.claim+"</span>")).join(""):"<div class='ph' style='margin:4px 14px'>无认领中任务——用 claim <id> --by <AI名> 认领</div>";
 if(Object.keys(byAg).length){
  agCard+="<div class='laneHead' style='margin:8px 14px 2px'>调度日志统计</div>";
  agCard+=Object.keys(byAg).map(a2=>"<div class='grow'><span class='dot' style='background:"+agentColor(a2)+"'></span><span class='nm'>"+a2+"</span><span style='color:var(--dim2);font:600 10px "+MONO+"'>完成 "+byAg[a2].done+" · 认领 "+byAg[a2].claims+"</span></div>").join("");}
 agCard+="</div>";
 R.push(agCard);
 const ws=(chk.warns||[]).slice(0,12),es=chk.errors||[];
 R.push("<div class='card'><h4>⚠ 审计线索</h4>"
  +(es.length?es.map(e=>"<div class='warn'>"+e+"</div>").join(""):"")
  +(ws.length?ws.map(w=>"<div class='warn'>"+w+"</div>").join(""):"<div class='hint' style='margin:4px 14px'>无警告</div>")+"</div>");
 d.innerHTML=h;
 document.getElementById("dashL").innerHTML=L.join("");
 document.getElementById("dashR").innerHTML=R.join("");}
document.querySelectorAll(".vtab").forEach(t=>{t.onclick=()=>setView(t.dataset.v);});

// ── 底部 IDE 面板（dock）：运行图（火车运行图式）/ 调度日志 ──
