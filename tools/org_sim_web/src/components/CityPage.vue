<script setup>
import { computed, ref } from "vue";
import { S, BUILDINGS, CITY_W, circ, RES_INFO, cityLayout, buildBlocked, cancelBuild, dismantle,
         queueBuild, buildWorkers, resTotal, capTotal, housingCap, interiorLayout, interiorUsed, interiorCap, shellBill } from "../sim.js";
import { usePanelSize } from "../panel.js";

/* 建筑页＝城市一排视图（03 §八：聚落沿街一字排开、市政厅居中、向两翼扩建）。
   建造管理自组织页 BuildSide 侧栏整体并入本页：两端扩建位就地开建造菜单、
   点建筑块开分座软装详情、顶部施工队列条 */

const CELL = 18;   // 每格像素宽：网页想多窄有多窄——18px 已可读，格多不占屏

/* 一排从左到右＝cityLayout()（sim.js 单一真相源：落成块+待建块，含左右翼预览次序），本组件纯渲染 */
const layout = computed(() => cityLayout());
const blocks = computed(() => layout.value.blocks);
const pendL = computed(() => layout.value.pendL);
const pendR = computed(() => layout.value.pendR);
const pendSat = computed(() => layout.value.pendSat);
const isCur = o => S.buildOrders[0] === o;

/* 扩建流程（03 §七）：点扩建位→就地展开建造菜单→选型开工（side 随扩建位已定） */
const menuSide = ref("");
function toggleMenu(side) { menuSide.value = menuSide.value === side ? "" : side; }
/* 矿井卫星区菜单只放仓库（分布式仓储——唯一可建卫星区的地形是矿洞） */
const buildables = computed(() => Object.entries(BUILDINGS).filter(([, d]) => d.shell && (menuSide.value !== "矿卫" || d.prebuilt)));
const storeys = ref(1);   // 民居可选 1/2 层（03 §二 木质上限2；双层成本工期×1.8、居住位×2）
function startBuild(b) {
  queueBuild("shell", b, null, null, menuSide.value, b === "民居" ? storeys.value : 1);
  menuSide.value = ""; storeys.value = 1;
}
const satBlocks = computed(() => S.citySat || []);
const storeysOf = e => (S.buildings[e.b] || [])[e.inst]?.storeys || 1;

/* 软装详情：点建筑块→下方面板按类型列出各座（原 BuildSide 分座安装/驻组织逻辑整体迁入）。
   默认选中市政厅——详情面板进门就有内容，不再空悬一块黑 */
const selB = ref("市政厅");
const selType = computed(() => selB.value ? BUILDINGS[selB.value] : null);
function pickBlock(b) { selB.value = selB.value === b ? "" : b; }
function instQueued(b, item, idx) {
  return S.buildOrders.some(o => o.b === b && o.item === item && o.idx === idx);
}
const lack = (r, n) => S.res[r] < n;
const installed = (b, inst) => (BUILDINGS[b].interior || []).filter(it => inst.interior[it.item]).length;

/* 块面状态行：市政厅=现名与人口；仓库=库存/容量（全城一库，按座叠容）；民居=居住位；
   其余=设备 n/m+驻组织（同型多座逐座独立软装） */
const rootName = computed(() => S.orgs.o01?.name || "聚落");
/* 仓库近满（≥90%）状态行示警——顶栏已有 lack 红，块面同口径 */
const whTight = () => capTotal() > 0 && resTotal() / capTotal() >= 0.9;
function statusLine(b, instIdx) {
  if (b === "市政厅") return `${rootName.value} · 人口 ${S.people.length}`;
  const inst = (S.buildings[b] || [])[instIdx] || { interior: {} };
  if (b === "仓库") return `库存 ${Math.floor(resTotal())}/${capTotal()}`;
  if (b === "民居") return `${inst.storeys === 2 ? "双层" : "单层"} · 位 ${((4 + (inst.interior["床铺"] ? 4 : 0)) * (inst.storeys || 1))}`;
  const m = (BUILDINGS[b].interior || []).length;
  const parts = [];
  if (m) parts.push(`设备 ${installed(b, inst)}/${m}`);
  if (inst.org) parts.push("驻" + (S.orgs[inst.org]?.name || "?"));
  return parts.join(" · ") || "空置";
}

/* 施工队列条（自 BuildSide 迁移）：当前单+进度+排队数+施工人力 */
const cur = computed(() => S.buildOrders[0] || null);
const pending = computed(() => S.buildOrders.slice(1));
const workers = computed(() => buildWorkers());
const orderLabel = o => o.kind === "shell"
  ? `${o.b}·新座硬装（${o.side === "矿卫" ? "矿井卫星区" : o.side === "左" ? "左" : "右"}翼${o.storeys === 2 ? "·双层" : ""}）`
  : o.b + circ(o.idx) + "·" + o.item;
/* 分部位料单（裁决32）：建造卡与软装详情显示逐部位 BOM */
const billOf = (b, st = 1) => shellBill(b, st);
const partStr = bill => Object.entries(bill).map(([r, n]) => RES_INFO[r]?.icon + n + r).join(" ");
/* 校验单一真相源（sim.js buildBlocked）：按钮禁用态与 queueBuild 同一规则 */
const shellWhy = b => buildBlocked("shell", b, null, -1, b === "民居" ? storeys.value : 1);
const itemWhy = (b, item, idx) => buildBlocked("interior", b, item, idx);
/* 剖视图（参考建筑管线的内景口径）：逐层内构格 + 在编工位——工序槽的人落在他那台设备的格上，
   非工序岗散在层内（世界内可观察行为的最小呈现，13 §三） */
function personsAt(b, idx) {
  const inst = S.buildings[b]?.[idx];
  const org = inst?.org ? S.orgs[inst.org] : null;
  const map = {}; let roam = 0;
  if (org) for (const sl of Object.values(org.slots)) {
    const n = sl.persons.length; if (!n) continue;
    const st = sl.def.step !== undefined ? org.steps[sl.def.step] : null;
    if (st) map[st.equip] = (map[st.equip] || 0) + n; else roam += n;
  }
  return { map, roam, org: org?.name || "" };
}

/* 软装详情面板 VSCode 式拖拽调高：上缘手柄，双击复位（解构见 OrgPage 同注） */
const { size: detH, onDown: detDown, onDbl: detDbl } = usePanelSize("cityDetail", "y", 250, 110, 520);
</script>

<template>
  <div id="citypage">
    <!-- 施工队列条：全城一根施工队（一单一个工地，可多单排队） -->
    <div id="ctool">
      <span class="qhead" title="硬装＝建筑体/窗位 · 软装＝设备/桌椅；施工人力＝工程队「施工」槽在编人数">施工</span>
      <template v-if="cur">
        <b>{{ orderLabel(cur) }}</b>
        <div class="bar"><i :style="{ width: (100 * cur.done / cur.work) + '%' }"></i></div>
        <span class="qpct">{{ (100 * cur.done / cur.work).toFixed(0) }}%</span>
        <i class="qcancel" title="撤单（全额返料，已投工时沉没）" @click="cancelBuild(0)">✕</i>
        <span class="qchip" v-for="(p2, i) in pending" :key="'q' + i"
              :title="orderLabel(p2) + '——点 ✕ 撤单'">{{ orderLabel(p2).slice(0, 12) }}<i @click="cancelBuild(i + 1)">✕</i></span>
        <span class="qwarn" v-if="!workers">无人施工</span>
        <span class="qsub">人力 {{ workers }}</span>
      </template>
      <span v-else class="qdim">无施工单——点一排两端的扩建位开工</span>
    </div>

    <!-- 城市一排：块宽=占格数，块内竖线底纹示意占格；两端扩建位 -->
    <div id="cityscroll">
      <div id="cityrow">
        <button class="expand" :class="{ on: menuSide === '左' }"
                title="左翼扩建位——就地展开建造菜单" @click="toggleMenu('左')">＋扩建</button>
        <!-- 左翼施工块：按队列倒序排（先完工的贴着既有街区，预览即落成后的次序） -->
        <div v-for="(p, i) in pendL" :key="'pl' + i" class="bblock con"
             :style="{ width: (CITY_W[p.b] || 2) * CELL + 'px' }"
             :title="p.b + (isCur(p) ? ' 施工中' : ' 排队中') + '——落成后进入左翼'">
          <div v-if="p.storeys === 2" class="upper"><span>2F</span></div>
          <div class="bname">{{ p.b }}</div>
          <span class="ctag">{{ isCur(p) ? "施工中" : "排队" }}</span>
          <div class="bar cbar"><i :style="{ width: (isCur(p) ? 100 * p.done / p.work : 0) + '%' }"></i></div>
        </div>
        <!-- 已落成建筑块 -->
        <div v-for="e in blocks" :key="e.b + e.inst" class="bblock built"
             :class="{ sel: selB === e.b, hall: e.b === '市政厅' }"
             :style="{ width: e.w * CELL + 'px' }"
             :title="(BUILDINGS[e.b]?.desc || '') + '｜点开下方软装详情'"
             @click="pickBlock(e.b)">
          <div v-if="storeysOf(e) === 2" class="upper"><span>2F</span></div>
          <div class="bname">{{ e.b }}<i v-if="e.b !== '市政厅'" class="seat">{{ circ(e.inst) }}</i></div>
          <div class="bstat" :class="{ tight: e.b === '仓库' && whTight() }"
               :title="e.b === '仓库' ? '全城库存总占位 / 分类容量合计（近满示警：工程队自动扩建可解）' : ''">{{ statusLine(e.b, e.inst) }}</div>
        </div>
        <!-- 右翼施工块：按队列正序向右长 -->
        <div v-for="(p, i) in pendR" :key="'pr' + i" class="bblock con"
             :style="{ width: (CITY_W[p.b] || 2) * CELL + 'px' }"
             :title="p.b + (isCur(p) ? ' 施工中' : ' 排队中') + '——落成后进入右翼'">
          <div v-if="p.storeys === 2" class="upper"><span>2F</span></div>
          <div class="bname">{{ p.b }}</div>
          <span class="ctag">{{ isCur(p) ? "施工中" : "排队" }}</span>
          <div class="bar cbar"><i :style="{ width: (isCur(p) ? 100 * p.done / p.work : 0) + '%' }"></i></div>
        </div>
        <button class="expand" :class="{ on: menuSide === '右' }"
                title="右翼扩建位——就地展开建造菜单" @click="toggleMenu('右')">＋扩建</button>
      </div>
    </div>

    <!-- 矿井卫星区：独立小条（矿洞处的分布式仓储） -->
    <div id="satrow">
      <span class="satlbl" title="矿洞是唯一可建卫星区的地形；卫星仓+80 矿堆容、集中短驳">矿井卫星区</span>
      <div class="satstrip">
        <button class="expand" :class="{ on: menuSide === '矿卫' }"
                title="卫星区扩建位——建分布式仓库" @click="toggleMenu('矿卫')">＋扩建</button>
        <div v-for="(p, i) in pendSat" :key="'ps' + i" class="bblock con"
             :style="{ width: (CITY_W[p.b] || 2) * CELL + 'px' }">
          <div class="bname">{{ p.b }}</div>
          <span class="ctag">{{ isCur(p) ? "施工中" : "排队" }}</span>
          <div class="bar cbar"><i :style="{ width: (isCur(p) ? 100 * p.done / p.work : 0) + '%' }"></i></div>
        </div>
        <div v-for="(e, i) in satBlocks" :key="'sb' + i" class="bblock built sat"
             :style="{ width: (CITY_W[e.b] || 2) * CELL + 'px' }">
          <div class="bname">{{ e.b }}<i class="seat">{{ circ(e.inst) }}</i></div>
          <div class="bstat">矿堆容 +80</div>
        </div>
      </div>
    </div>

    <!-- 建造菜单（就地展开）：各建筑类型卡＝名/占宽/成本芯片/工期；资源不足禁用并红成本 -->
    <div v-if="menuSide" id="bmenu">
      <div class="bmhead">
        <b>{{ menuSide === "矿卫" ? "矿井卫星区" : menuSide + "翼扩建" }}</b>
        <span class="bmsub">{{ menuSide === "矿卫"
          ? "分布式仓储：卫星仓扩矿场堆容（+80/座）、集中短驳"
          : "选建筑类型——资源即扣，工程队按队施工；落成后排入" + menuSide + "翼" }}</span>
        <button @click="menuSide = ''">收起</button>
      </div>
      <div v-if="menuSide !== '矿卫'" class="storeys">
        <span>民居层数：</span>
        <button :class="{ on: storeys === 1 }" @click="storeys = 1">单层</button>
        <button :class="{ on: storeys === 2 }" @click="storeys = 2"
                title="木质上限2层（03 §二）；成本工期×1.8、居住位×2">双层</button>
      </div>
      <div class="bmcards">
        <button v-for="[b, d] in buildables" :key="b" class="bmcard"
                :disabled="!!shellWhy(b)"
                :title="(shellWhy(b) ? shellWhy(b) + '｜' : '') + d.desc + ' · 工期 ' + d.shell.work + '人时'"
                @click="startBuild(b)">
          <span class="bmctop"><b>{{ b }}</b><i v-if="d.late" class="latetag">后期</i>
            <i class="bmw">占{{ CITY_W[b] }}格{{ menuSide !== '矿卫' && b === '民居' && storeys === 2 ? '×2层' : '' }}</i></span>
          <span class="bmcdesc">{{ d.desc }}</span>
          <span class="bmcmeta">工期 {{ billOf(b, b === '民居' && storeys === 2 ? 2 : 1).work }} 人时 · 逐部位料单：</span>
          <span class="bpcost" v-for="[pn, bill] of Object.entries(billOf(b, b === '民居' && storeys === 2 ? 2 : 1).parts)"
                :key="pn" :title="pn + '：' + partStr(bill)">{{ pn }} {{ partStr(bill) }}</span>
        </button>
      </div>
    </div>

    <!-- 弹性占位：详情面板钉底、固定高度后由它吸收纵向空隙 -->
    <div id="cfill"></div>
    <!-- 软装详情：类型下实例列表+设备行+安装按钮（同型多座、逐座独立软装）；高度可拖拽（panel.js） -->
    <div class="pz h" title="拖动调高 · 双击复位" @mousedown="detDown" @dblclick="detDbl"></div>
    <div id="cdetail" :style="{ height: detH + 'px' }">
      <template v-if="selB">
        <div class="cdhead"><b>{{ selB }}</b><span class="cddesc">{{ selType?.desc }}</span></div>
        <!-- 建一座的逐部位料单（分部位 BOM） -->
        <div class="bomrow" v-if="!selType?.prebuilt">
          <span class="dim">建一座需：</span>
          <span class="bpcost" v-for="[pn, bill] of Object.entries(billOf(selB).parts)" :key="pn"
                :title="pn">{{ pn }} {{ partStr(bill) }}</span>
          <span class="dim">· {{ billOf(selB).work }} 人时</span>
        </div>
        <div v-for="(inst, idx) in (S.buildings[selB] || [])" :key="idx" class="inst">
          <div class="ihead">
            <b>{{ circ(idx) }}</b>
            <span class="fx" v-if="inst.org">驻 {{ S.orgs[inst.org]?.name }}</span>
            <span class="fx" v-if="(selType?.interior || []).length">内构 {{ interiorUsed(selB, idx) }}/{{ interiorCap(selB, inst.storeys || 1) }} 格 · 设备 {{ installed(selB, inst) }}/{{ selType.interior.length }}</span>
            <span class="fx" v-if="selB === '民居'">居住位 {{ (4 + (inst.interior["床铺"] ? 4 : 0)) * (inst.storeys || 1) }}</span>
          </div>
          <!-- 仓库分类：逐座限定收货类型（裁决34）——某类容量＝收该类的座数×单座容量，分布式仓地基 -->
          <div v-if="selB === '仓库'" class="wacc">
            <span class="fx">收货类型：</span>
            <select :value="inst.accepts || '全部'" @change="inst.accepts = $event.target.value">
              <option v-for="opt in ['全部', '基础原料', '材料', '制品']" :key="opt" :value="opt">{{ opt }}</option>
            </select>
            <span class="fx">该类容量＝收该类的仓库座数 ×{{ S.knobs.cap }}（各类独立）</span>
          </div>
          <!-- 剖视图：逐层内构格（自动布局：从左到右贪心），工序岗的人点在他的设备格上 -->
          <div v-if="(selType?.interior || []).length" class="floor">
            <div v-for="(layer, li) in interiorLayout(selB, idx)" :key="'l' + li" class="flayer">
              <span class="ftag">{{ (inst.storeys || 1) > 1 ? (li + 1) + "F" : "内构" }}</span>
              <div class="fcells">
                <div v-for="p in layer" :key="p.item" class="fcell" :style="{ flexGrow: p.w }"
                     :title="p.item + (personsAt(selB, idx).map[p.item] ? `：${personsAt(selB, idx).map[p.item]} 人在岗` : '：在装待岗')">
                  <span>{{ p.item.slice(0, 2) }}</span>
                  <i v-if="personsAt(selB, idx).map[p.item]">{{ "●".repeat(Math.min(5, personsAt(selB, idx).map[p.item])) }}</i>
                </div>
                <div v-if="personsAt(selB, idx).roam" class="fcell roam" :style="{ flexGrow: 2 }"
                     :title="'非工序岗在编 ' + personsAt(selB, idx).roam + ' 人（管理/信息/值守）'">
                  {{ "◦".repeat(Math.min(6, personsAt(selB, idx).roam)) }}
                </div>
              </div>
            </div>
            <div v-if="!interiorLayout(selB, idx).some(l => l.length)" class="fempty">空内构——软装从下方逐项安装（自动布局：逐层从左到右）</div>
          </div>
          <div class="irow" v-for="it in (selType?.interior || [])" :key="it.item">
            <div class="ileft">
              <span class="iname">{{ it.item }}</span>
              <span class="fx">{{ it.unlock || it.effect }}</span>
            </div>
            <template v-if="inst.interior[it.item]">
              <span class="okk">已装</span>
              <button class="dism" title="拆卸返料（全额；拆设备=对应工序停摆）——库满缺料时的腾挪出口"
                      @click="dismantle(selB, idx, it.item)">拆卸</button>
            </template>
            <span v-else-if="instQueued(selB, it.item, idx)" class="dim">施工中</span>
            <button v-else :disabled="!!itemWhy(selB, it.item, idx)"
                    :title="itemWhy(selB, it.item, idx) || it.work + '人时'"
                    @click="queueBuild('interior', selB, it.item, idx)">
              安装<span class="cost" v-for="[r, n] of Object.entries(it.cost)" :key="r"
                    :class="{ lack: lack(r, n) }">{{ RES_INFO[r].icon }}{{ n }}</span>
            </button>
          </div>
          <div v-if="!(selType?.interior || []).length" class="cdnone">本型建筑无软装项——硬装落成即交付</div>
        </div>
      </template>
      <div v-else class="cdhint">点城市一排中的建筑块——按类型管理各座软装（设备逐座安装；驻组织显示在块面上）</div>
    </div>
  </div>
</template>

<style scoped>
#citypage { flex: 1; display: flex; flex-direction: column; min-height: 0; }

/* 施工队列条 */
#ctool { display: flex; align-items: center; gap: 8px; padding: 7px 14px; font-size: 12px;
         border-bottom: 1px solid var(--line); background: #131826; flex: none; flex-wrap: wrap; }
.qhead { font-weight: 700; font-size: 12.5px; }
#ctool .bar { flex: 1; min-width: 60px; max-width: 320px; }
.qpct { color: var(--dim); font-variant-numeric: tabular-nums; }
.qcancel, .qchip i { cursor: pointer; color: var(--dim); font-style: normal; font-size: 11px; }
.qcancel:hover, .qchip i:hover { color: var(--bad); }
.qchip { background: var(--panel2); border: 1px solid var(--line); border-radius: 8px;
         padding: 1px 7px; font-size: 10.5px; display: inline-flex; gap: 4px; align-items: center;
         color: var(--dim); }
.qchip i { font-size: 10px; }
.qwarn { color: var(--warn); font-size: 10.5px; }
.qsub { color: var(--dim); font-size: 10.5px; margin-left: auto; }
.qdim { color: var(--dim); font-size: 11px; }   /* 空队列提示与「施工」标签拉开主次（曾同灰度像禁用态） */

/* 城市一排 */
#cityscroll { overflow-x: auto; flex: none; border-bottom: 1px solid var(--line);
              background: #10141d; }
#cityrow { display: flex; align-items: stretch; gap: 4px; padding: 12px;
           width: max-content; min-width: 100%; }
.bblock { height: 68px; border: 1px solid var(--line2); border-radius: 7px; padding: 6px 8px;
          flex: none; overflow: hidden;
          background-color: var(--panel3);
          background-image: linear-gradient(90deg, #ffffff0e 1px, transparent 1px);
          background-size: 18px 100%; }   /* 18px＝CELL：每格一道竖线示意占格 */
.bblock.built { cursor: pointer; }
.bblock.built:hover { border-color: var(--acc); }
.bblock.sel { border-color: var(--acc); background-color: #2b3550; }
.bblock.hall { border-color: var(--warn); }
.bblock.con { border-style: dashed; opacity: .6; background-color: #1a2030; }
.bname { font-weight: 600; font-size: 12px; white-space: nowrap; }
.bname .seat { font-style: normal; color: var(--dim); font-size: 11px; margin-left: 2px; }
.bstat { color: var(--dim); font-size: 10px; line-height: 1.35; margin-top: 2px; overflow: hidden; }
.bstat.tight { color: var(--warn); font-weight: 600; }   /* 仓库近满：块面同顶栏 lack 口径示警 */
.ctag { color: var(--warn); font-size: 10px; }
.cbar { margin-top: 3px; }
.expand { flex: none; width: 64px; border-style: dashed; color: var(--dim);
          background: transparent; font-size: 11.5px; }
.expand:hover { color: var(--fg); }
.expand.on { border-style: solid; color: var(--acc); border-color: var(--acc); }

/* 建造菜单 */
#bmenu { flex: none; padding: 8px 14px; border-bottom: 1px solid var(--line); background: var(--panel); }
.bmhead { display: flex; align-items: center; gap: 8px; font-size: 12.5px; margin-bottom: 6px; }
.bmhead button { margin-left: auto; padding: 2px 10px; font-size: 11px; }
.bmsub { color: var(--dim); font-size: 11px; }
.bmcards { display: flex; gap: 8px; flex-wrap: wrap; }
.bpcost { background: var(--panel2); border: 1px solid var(--line); border-radius: 8px;
          padding: 1px 7px; font-size: 10.5px; color: var(--dim); margin: 1px 3px 1px 0;
          display: inline-flex; gap: 3px; }
.bomrow { display: flex; align-items: center; flex-wrap: wrap; gap: 2px; margin: 2px 0 6px; font-size: 11px; }
.bomrow .dim { color: var(--faint); font-size: 10.5px; }
.bmcard { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; width: 200px;
          text-align: left; padding: 7px 10px; }
.bmcard:disabled { opacity: .45; }
.bmctop { display: flex; align-items: center; gap: 6px; width: 100%; }
.bmctop b { font-size: 12.5px; }
.bmctop .bmw { font-style: normal; color: var(--dim); font-size: 10px; margin-left: auto; }
.latetag { font-style: normal; font-size: 10px; color: var(--warn); }
.bmcdesc { color: var(--dim); font-size: 10.5px; line-height: 1.35; }
.bmcmeta { color: var(--dim); font-size: 10.5px; }
.bmcard .cost { margin-right: 6px; }

/* 软装详情 */
#cfill { flex: 1; min-height: 0; }
#cdetail { flex: none; overflow-y: auto; padding: 8px 14px 14px; background: var(--panel); }
.cdhead { display: flex; align-items: baseline; gap: 8px; margin-bottom: 4px; }
.cdhead b { font-size: 13px; }
.cddesc { color: var(--dim); font-size: 11px; }
.inst { margin-top: 6px; border-top: 1px solid var(--line); padding-top: 4px; }
.ihead { display: flex; align-items: baseline; gap: 6px; padding: 2px 0; }
.ihead b { font-size: 12px; }
.ihead .fx { color: var(--dim); font-size: 10.5px; }
.irow { display: flex; align-items: center; gap: 6px; padding: 4px 0; }
.ileft { display: flex; flex-direction: column; min-width: 0; }
.ileft .iname { font-size: 11.5px; font-weight: 600; }
.ileft .fx { color: var(--dim); font-size: 10.5px; }
.irow button { margin-left: auto; flex: none; display: inline-flex; align-items: center; gap: 3px;
               font-size: 11px; padding: 2px 7px; }
.okk { margin-left: auto; color: #b8ecd0; font-size: 10.5px; background: #1f5c3e;
       border-radius: 8px; padding: 1px 7px; }
.wacc { display: flex; align-items: center; gap: 6px; padding: 2px 0 4px; }
.wacc select { font-size: 11px; }
.irow .dism { flex: none; font-size: 10px; padding: 1px 7px; color: var(--dim); }
.irow .dism:hover { color: var(--bad); border-color: var(--bad); }
/* 剖视图 */
.floor { margin: 4px 0 6px; }
.flayer { display: flex; align-items: center; gap: 6px; margin-bottom: 3px; }
.ftag { font-size: 9.5px; color: var(--faint); width: 26px; flex: none; text-align: right; }
.fcells { display: flex; gap: 2px; flex: 1; min-width: 0; }
.fcell { border: 1px solid var(--line2); border-radius: 4px; background: #1a2233;
         min-width: 0; padding: 2px 5px; font-size: 10px; display: flex; flex-direction: column;
         align-items: center; justify-content: center; line-height: 1.25; }
.fcell span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
.fcell i { font-style: normal; color: var(--ok); font-size: 9px; letter-spacing: 1px; }
.fcell.roam { border-style: dashed; color: var(--dim); flex-direction: row; letter-spacing: 2px; }
.fempty { color: var(--faint); font-size: 10.5px; padding: 2px 0 4px 32px; }
.irow .dim { margin-left: auto; color: var(--warn); font-size: 10.5px; }
.cdnone { color: var(--faint); font-size: 10.5px; padding: 4px 0; }
.cdhint { color: var(--faint); font-size: 11px; padding: 10px 0; }
#satrow { display: flex; align-items: center; gap: 10px; margin-top: 8px; }
.satlbl { font-size: 11px; color: var(--dim); writing-mode: vertical-lr; letter-spacing: 2px; }
.satstrip { display: flex; gap: 6px; align-items: stretch; padding: 4px 8px;
            background: #141a26; border: 1px dashed var(--line); border-radius: 9px; }
.bblock.sat { border-style: dashed; }
.upper { height: 12px; margin: 1px 3px 0; border: 1px solid var(--line2); border-radius: 4px;
         background: #ffffff12; font-size: 8.5px; color: var(--dim); display: flex;
         align-items: center; justify-content: center; letter-spacing: 2px; }
.storeys { display: flex; align-items: center; gap: 5px; margin: 4px 0 2px; font-size: 11.5px; color: var(--dim); }
.storeys button { padding: 2px 9px; font-size: 11px; }
</style>
