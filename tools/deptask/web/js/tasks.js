// ── 新建/编辑任务弹窗（同一表单双模式；编辑时 id 锁定） ──
let editTarget=null;
let planParent=null;
function openTaskForm(editId,parentId){editTarget=editId||null;planParent=parentId||null;
 const m=document.getElementById("modal");m.style.display="flex";
 document.getElementById("ntTitle").textContent=editId?("✎ 编辑任务 · "+editId)
  :(planParent?("✂ 拆解 "+planParent+" → 子任务"):"➕ 新建任务");
 document.getElementById("ntGo").textContent=(editId||planParent)?"创建子任务":"创建";
 document.getElementById("ntGo").textContent=editId?"保存":"创建";
 const idIn=document.getElementById("ntId");
 idIn.value=editId||"";idIn.disabled=!!editId;   // id 是全部引用的锚点，编辑时锁定
 idIn.parentElement.style.display=editId?"none":"flex";
 const n=editId?byId[editId]:null;
 document.getElementById("ntName").value=n?n.name:"";
 const ls=document.getElementById("ntLane");
 ls.innerHTML=lanes.map(l=>"<option"+(n&&n.lane===l?" selected":"")+">"+l+"</option>").join("");
 const st=document.getElementById("ntStatus");
 st.innerHTML=STATUS.map(s=>"<option"+((n?n.status:"可开工")===s?" selected":"")+">"+s+"</option>").join("");
 document.getElementById("ntPrs").value=n?(n.prs||[]).join(","):(planParent||"");
 document.getElementById("ntDomain").value=n?((Array.isArray(n.domain)?n.domain:(n.domain||"").split(",")).filter(Boolean)).join(","):"";
 document.getElementById("ntDoc").value=n?(n.doc||""):"";
 document.getElementById("ntNote").value=n?(n.note||""):"";
 hideCtx();
 if(!editId)document.getElementById("ntName").focus();}
function closeModal(){document.getElementById("modal").style.display="none";editTarget=null;}
function submitTaskForm(){
 const name=document.getElementById("ntName").value.trim();
 const lane=document.getElementById("ntLane").value,status=document.getElementById("ntStatus").value;
 const domain=(document.getElementById("ntDomain").value||"").split(/[,;]/).map(s=>s.trim()).filter(Boolean);
 const doc=document.getElementById("ntDoc").value.trim(),note=document.getElementById("ntNote").value.trim();
 const newPrs=(document.getElementById("ntPrs").value||"").split(",").map(s=>s.trim()).filter(Boolean);
 if(editTarget){const n=byId[editTarget];
  if(!n){closeModal();return;}
  n.name=name||n.name;n.lane=lane;n.status=status;n.domain=domain;n.doc=doc;n.note=note;
  (n.prs||[]).filter(p=>!newPrs.includes(p)).forEach(p=>delEdge({a:p,b:editTarget}));
  newPrs.filter(p=>!(n.prs||[]).includes(p)).forEach(p=>{if(byId[p])addEdge(p,editTarget);
   else alert("前置不存在，已跳过："+p);});
  markEdit(editTarget);measureCards();rebuildView();showPanel(n);buildSide(curView);closeModal();return;}
 let id=document.getElementById("ntId").value.trim();
 if(planParent&&!id){let k=1;while(byId[planParent+"-"+k])k++;id=planParent+"-"+k;
  document.getElementById("ntId").value=id;}
 if(!id){alert("id 必填");return;}
 if(byId[id]){alert("id 已存在："+id);return;}
 const n={id,kind:"任务",name:name||id,lane,status,prs:[],domain,tree:"",note,doc,
  x:null,y:null,px:0,py:0,lines:[],cw:150,ch:56,inP:[],outP:[],_hit:false};
 nodes.push(n);byId[id]=n;prsOf[id]=[];blocksOf[id]=[];
 newPrs.forEach(p=>{if(byId[p])addEdge(p,id);else alert("前置不存在，已跳过："+p);});
 markEdit(id);measureCards();rebuildView();buildSide(curView);closeModal();
 sel=id;selSet=new Set([id]);jump(id);
 if(planParent&&byId[planParent]){  // 父任务自动化：注记"已拆解为"
  const pn=byId[planParent];
  const tag="已拆解为 "+id;
  if(!(pn.note||"").includes(tag))pn.note=(pn.note?pn.note+"；":"")+tag;
  markEdit(planParent);measureCards();rebuildView();}
 closeRel();  // 拆解表单关闭浮窗（若开）
}
function doRelease(id){const n=byId[id];if(!n)return;
 if(n.claim){log_event("release",id,n.claim);}
 n.claim="";markEdit(id);showPanel(n);dirty=true;}
function delTask(id){const n=byId[id];if(!n)return;
 const linked=edges.filter(e=>e.a===id||e.b===id).length;
 if(!confirm("删除任务「"+n.name+"」（"+id+"）及其 "+linked+" 条依赖边？\n此操作导出后生效，源文件覆盖前可反悔。"))return;
 edges=edges.filter(e=>e.a!==id&&e.b!==id);
 CLUSTERS.forEach(c=>{const i=c.members.indexOf(id);if(i>=0)c.members.splice(i,1);});
 nodes.splice(nodes.indexOf(n),1);
 delete byId[id];delete prsOf[id];delete blocksOf[id];
 delete memberOf[id];
 sel=null;selSet=new Set();selEdge=null;hi=null;
 markEdit(id);measureCards();rebuildView();buildSide(curView);
 document.getElementById("inspector").innerHTML="<div class='ph'>已删除 "+id+"</div>";dirty=true;}
function exportTxt(){ // 编辑闭环：导出完整源文件（状态/依赖/布局/新任务全含）→ 覆盖源 txt → --check
 const bad=[];
 nodes.forEach(n=>{(n.prs||[]).forEach(p=>{
  if(p===n.id)bad.push(n.id+" 自环前置");
  else if(!byId[p])bad.push(n.id+" 前置悬空 "+p);});});
 if(bad.length&&!confirm("发现 "+bad.length+" 处问题（导出后 --check 会报 ERROR）：\n"+bad.slice(0,6).join("\n")+"\n仍要导出吗？"))return;
 let out="# 任务依赖图（看板导出——覆盖 docs/项目/任务依赖图.txt 后运行 python tools/deptask/gen.py --check）\n";
 out+="# 校验: python tools/deptask/gen.py --check   生成: python tools/deptask/gen.py\n";
 out+="线序: "+lanes.join(", ")+"\n";
 if(divideX!=null)out+="分割线: "+Math.round(divideX)+"\n";
 out+="\n";
 CLUSTERS.forEach(c=>{out+="簇 "+c.id+" | 名称="+c.name+" | 成员="+c.members.join(",")
  +(folded[c.id]?" | 折叠=1":"")+(c.note?" | 注="+c.note:"")+"\n";});
 nodes.forEach(n=>{out+=(n.kind==="里程碑"?"里程碑 ":"任务 ")+n.id
  +" | 名称="+n.name+" | 线="+n.lane+" | 状态="+n.status
  +(n.prs&&n.prs.length?" | 前置="+n.prs.join(","):"")
  +(n.domain&&n.domain.length?" | 域="+(Array.isArray(n.domain)?n.domain.join(","):n.domain):"")+(n.tree?" | 树="+n.tree:"")
  +(n.x!=null?" | 位置="+n.px.toFixed(1)+","+n.py.toFixed(1):"")  // 「自动重排」后 x 置 null，不写位置＝保留 dagre 自由态
  +(n.exempt?" | 豁免=1":"")+(n.tier?" | 级="+n.tier:"")+(n.claim?" | 认领="+n.claim:"")
  +(n.doc?" | 文档="+n.doc:"")+(n.note?" | 注="+n.note:"")+"\n";});
 const a=document.createElement("a");
 a.href=URL.createObjectURL(new Blob([out],{type:"text/plain;charset=utf-8"}));
 a.download="任务依赖图.txt";a.click();}
