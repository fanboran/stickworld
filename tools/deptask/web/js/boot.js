// ── 启动 ──
measureCards();
if(!manual0)divideX=null;
rebuildView();                 // 先建视图集（VN/VE），簇虚拟节点取成员质心
if(manual0){nodes.forEach(n=>{n.px=n.x;n.py=n.y;});rebuildView();}
else dagreLayout();            // 对视图集布局并回写成员坐标
rebuildView();                 // 布局后重建：折叠簇卡片取新质心
locateActive();
resize();                      // 顶栏在 core 阶段测量时图例/泳道胶囊尚未填充，此处重测 BAR_H 并同步全部面板 top（否则 vbar 停在旧值被顶栏压住）
setView((location.hash.match(/view=(\w+)/)||[])[1]||"graph",true);   // hash 路由：#view=producer 直达；force=启动强制初始化
addEventListener("hashchange",()=>{const v=(location.hash.match(/view=(\w+)/)||[])[1];if(v&&v!==curView)setView(v);});
let _last=0;
requestAnimationFrame(function loop(ts){if(critOnly||nodes.some(n=>n.claim)){animT++;dirty=true;}  // 蚂蚁线/认领呼吸：仅有关键路径模式或已认领任务时常驻重绘
 if(dirty&&ts-_last>16){draw();_last=ts;}
 requestAnimationFrame(loop);});
