<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { S, ORGS, TERRAIN, CIRC, person, membersOf, wipOf, orgEquip, stepDesc, slotProduct,
         idle, select, delOrg, feed, slotCandidates, createBlocked,
         putPerson, pullPersons, setProduct, createOrgAt } from "../sim.js";

const host = computed(() => {
  const h = {};
  for (const o of Object.values(S.orgs))
    for (const slot of Object.values(o.slots))
      if (slot.institution && S.orgs[slot.institution]) h[slot.institution] = { org: o.id, fn: slot.def.fn };
  return h;
});
function depthOf(id) {
  let d = 0, cur = id;
  while (host.value[cur]) { cur = host.value[cur].org; d += 1; if (d > 8) break; }
  if (d === 0 && S.orgs[id] && S.orgs[id].kind !== "hall") d = 1;
  return d;
}

/* ── 树形垂直布局：叶子按序铺开、父节点在子块垂直居中（连线不重合，首卡自然下移） ── */
const cardH = o => 34 + Object.keys(o.slots).length * 24;
const layoutY = computed(() => {
  const kids = {};
  for (const o of Object.values(S.orgs))
    kids[o.id] = Object.values(o.slots).map(s => s.institution).filter(x => x && S.orgs[x]);
  const y = {}; let cursor = 0; const seen = new Set();
  const place = id => {
    if (seen.has(id)) return y[id] ?? 0;
    seen.add(id);
    const ks = kids[id];
    if (!ks.length) { y[id] = cursor; cursor += cardH(S.orgs[id]) + 12; return y[id]; }
    const ys = ks.map(place);
    // 父卡对准首个入驻槽的行位（市政厅自然下移到生产槽附近，连线就近不交叉）；
    // 父卡与子树分属不同列，允许垂直重叠，不受游标钳制
    const firstSlotIdx = Object.values(S.orgs[id].slots)
      .findIndex(s => s.institution && S.orgs[s.institution]);
    y[id] = Math.max(ys[0] - Math.max(0, firstSlotIdx) * 24, 0);
    cursor = Math.max(cursor, y[id] + cardH(S.orgs[id]) + 12);
    return y[id];
  };
  const root = S.order.find(id => S.orgs[id]?.kind === "hall") || S.order[0];
  if (root) place(root);
  for (const id of S.order)
    if (S.orgs[id] && y[id] === undefined) { y[id] = cursor; cursor += cardH(S.orgs[id]) + 12; }
  return y;
});
const colLayout = computed(() => {
  const y = layoutY.value;
  const byDepth = {};
  for (const id of S.order) {
    if (!S.orgs[id]) continue;
    (byDepth[depthOf(id)] ||= []).push(id);
  }
  const maxD = Math.max(...Object.keys(byDepth).map(Number));
  const cols = [];
  for (let d = 0; d <= maxD; d++) {
    const ids = (byDepth[d] || []).sort((a, b) => y[a] - y[b]);
    let bottom = 0; const items = [];
    for (const id of ids) {
      const top = Math.max(y[id], bottom + (items.length ? 12 : 0));
      items.push({ org: S.orgs[id], mt: items.length ? top - bottom : top });
      bottom = top + cardH(S.orgs[id]);
    }
    cols.push({ items });
  }
  return cols;
});

function borrowsOf(orgId) { return S.borrows[orgId] || []; }
function chipName(pid) { return person(pid)?.name || "?"; }
/* 同名在编聚合显示：同质化槽一颗「村民×3」芯片 */
function chipsOf(slot) {
  const m = new Map();
  for (const pid of slot.persons) {
    const n = person(pid)?.name || "?";
    m.set(n, (m.get(n) || 0) + 1);
  }
  return [...m].map(([n, c]) => c > 1 ? `${n}×${c}` : n);
}
/* 槽位解锁看本组织所驻建筑实例（03 §一），不看全城 */
const isLocked = (o, slot) => !!(slot.def.req && !orgEquip(o, slot.def.req.item));
function clickSlot(o, fn, slot) {
  if (isLocked(o, slot)) {
    const d = slot.def;
    feed(`${fn} 槽被禁：需 ${d.req.b}${d.req.item ? " 并装 " + d.req.item : ""}（组织无建筑仍可基础运转）`, "bad");
    return;
  }
  if (S.sel === o.id && S.selSlot === fn) { select(o.id, null); return; }   // 再点收起
  pickPerson.value = "";
  select(o.id, fn);
}
const opsOpen = (o, fn, slot) => S.sel === o.id && S.selSlot === fn && !isLocked(o, slot);
const pickPerson = ref("");
const emptySlot = slot => !slot.persons.length && !slot.institution;
function candTitle(name) {
  const t = ORGS[name];
  const desc = t.steps && t.steps.length ? t.steps.map(stepDesc).join("→")
    : (t.slots || []).map(s => s.fn + (s.homog ? "×" + s.n : "")).join("/");
  const blocked = createBlocked(name);
  return desc + (blocked ? "｜" + blocked : "");
}
const POS_NAME = { run: "必需岗", flex: "借调岗", any: "弹性岗", opt: "增益岗" };

/* ── 嵌套连线：机构入驻槽 → 子组织卡片（SVG 覆盖层，肘形线） ── */
const svg = ref(null);
const linesKey = computed(() => Object.values(S.orgs).map(o =>
  o.id + ":" + Object.values(o.slots).map(s => s.institution).join(",")).join(";"));
function drawLines() {
  const root = document.getElementById("orgCols");
  if (!root || !svg.value) return;
  const c = root.getBoundingClientRect();
  const sx = root.scrollLeft, sy = root.scrollTop;
  const d = [];
  for (const o of Object.values(S.orgs))
    for (const [fn, slot] of Object.entries(o.slots)) {
      if (!slot.institution || !S.orgs[slot.institution]) continue;
      const from = root.querySelector(`[data-slot="${o.id}|${fn}"]`);
      const to = root.querySelector(`[data-org="${slot.institution}"]`);
      if (!from || !to) continue;
      const a = from.getBoundingClientRect(), b = to.getBoundingClientRect();
      const x1 = a.right - c.left + sx, y1 = a.top - c.top + sy + a.height / 2;
      const x2 = b.left - c.left + sx, y2 = b.top - c.top + sy + 14;
      d.push(`M${x1},${y1} H${x1 + 10} V${y2} H${x2}`);
    }
  svg.value.setAttribute("width", Math.max(root.scrollWidth, c.width));
  svg.value.setAttribute("height", Math.max(root.scrollHeight, c.height));
  svg.value.innerHTML = d.map(p =>
    `<path d="${p}" fill="none" stroke="#e359c4" stroke-opacity=".55" stroke-width="1.5"/>`).join("");
}
watch(linesKey, () => nextTick(drawLines), { flush: "post" });
watch(colLayout, () => nextTick(drawLines), { flush: "post" });
onMounted(() => {
  nextTick(drawLines);
  window.addEventListener("resize", drawLines);
});
onUnmounted(() => window.removeEventListener("resize", drawLines));
</script>

<template>
  <div id="orgCols">
    <svg ref="svg" class="lines"></svg>
    <div class="ocol" v-for="(col, ci) in colLayout" :key="ci">
      <div v-for="it in col.items" :key="it.org.id" class="card" :data-org="it.org.id"
           :style="{ marginTop: it.mt + 'px' }"
           :class="{ hall: it.org.kind === 'hall', sel: S.sel === it.org.id && !S.selSlot }">
        <div class="hd" @click="select(it.org.id)">
          <span>{{ it.org.name }}</span><span class="tier">L{{ it.org.tier }}</span>
          <span class="sub">{{ it.org.kind === "hall" ? "根节点" :
            (host[it.org.id] ? "入驻·" + host[it.org.id].fn + "槽" : "未入驻") }}{{ it.org.bldgType
              ? (it.org.bldg ? " · 驻" + it.org.bldg.b + CIRC[it.org.bldg.idx] : " · 缺" + it.org.bldgType)
              : "" }} · 在编 {{ membersOf(it.org) }}</span>
          <button v-if="it.org.kind !== 'hall'" class="del warn" title="解散组织（人员回待业）"
                  @click.stop="delOrg(it.org.id)">×</button>
        </div>
        <div v-for="(slot, fn) in it.org.slots" :key="fn" class="slotwrap">
          <div class="srow" :data-slot="it.org.id + '|' + fn"
               :class="{ locked: isLocked(it.org, slot), sel: S.sel === it.org.id && S.selSlot === fn }"
               @click="clickSlot(it.org, fn, slot)">
            <span class="fn" :class="'p-' + (slot.def.pos || 'run')"
                  :title="POS_NAME[slot.def.pos || 'run'] + '｜' + (slot.def.role || '')">{{ fn }}</span>
            <span v-if="slot.def.homog" class="cnt">{{ slot.persons.length }}/{{ slot.def.n }}</span>
            <template v-if="slot.persons.length || slot.institution">
              <span v-for="c in chipsOf(slot)" :key="c" class="chip">{{ c }}</span>
              <span v-if="slot.institution" class="chip orgchip">机构·{{ S.orgs[slot.institution]?.name || "?" }}</span>
            </template>
            <span v-else class="chip empty">空槽</span>
            <!-- 借调动效：目标槽半透明人名+慢速圈 -->
            <span v-for="(b, i) in borrowsOf(it.org.id).filter(x => x.to === fn)" :key="'g' + i" class="ghostbox">
              <span>{{ chipName(it.org.slots[b.from]?.persons[0]) }}↦</span><span class="spin"></span>
            </span>
            <span v-if="slot.def.step !== undefined && it.org.steps[slot.def.step]?.wip" class="wip">
              {{ it.org.steps[slot.def.step].wip }} {{ (wipOf(it.org)[it.org.steps[slot.def.step].wip] || 0).toFixed(1) }}
            </span>
            <span v-if="slot.persons.length" class="spin"
                  :class="{ paused: borrowsOf(it.org.id).filter(x => x.from === fn).length >= slot.persons.length }"></span>
            <span v-if="isLocked(it.org, slot)" class="need">
              需{{ slot.def.req.b }}{{ slot.def.req.item ? "·" + slot.def.req.item : "" }}
            </span>
            <span class="par">
              <template v-if="slot.def.terrain">{{ slot.def.terrain }}{{ slot.product ? "·" + slotProduct(slot) : "" }}</template>
              <template v-else-if="slot.def.step !== undefined && it.org.steps[slot.def.step]">{{ stepDesc(it.org.steps[slot.def.step]) }}</template>
              <template v-else-if="slot.def.role">{{ slot.def.role.slice(0, 14) }}</template>
            </span>
          </div>
          <!-- 槽位操作内联：构筑子组织（递归）/ 派人 / 选产物 -->
          <div v-if="opsOpen(it.org, fn, slot)" class="sops" @click.stop>
            <template v-if="emptySlot(slot) && slotCandidates(fn).length">
              <span class="ohint b">构筑：</span>
              <button v-for="name in slotCandidates(fn)" :key="name" class="cbtn"
                      :class="{ late: ORGS[name].late }" :disabled="!!createBlocked(name)"
                      :title="candTitle(name)"
                      @click="createOrgAt(it.org.id, fn, name)">＋{{ name }}<i v-if="ORGS[name].late">后期</i></button>
            </template>
            <select v-model="pickPerson" :disabled="slot.def.homog && slot.persons.length >= slot.def.n">
              <option value="">{{ slot.def.homog && slot.persons.length >= slot.def.n ? "坑位已满" : "待业人员…" }}</option>
              <option v-for="p in idle()" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
            <button :disabled="!pickPerson" @click="putPerson(it.org.id, fn, pickPerson); pickPerson = ''">派入</button>
            <button v-if="slot.persons.length" @click="pullPersons(it.org.id, fn)">撤出全部</button>
            <select v-if="TERRAIN[slot.def.terrain] && TERRAIN[slot.def.terrain].products.length > 1"
                    :value="slotProduct(slot)" title="选产物"
                    @change="setProduct(it.org.id, fn, $event.target.value)">
              <option v-for="p in TERRAIN[slot.def.terrain].products" :key="p" :value="p">{{ p }}</option>
            </select>
            <span class="ohint">{{ slot.def.role || "" }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
#orgCols { flex: 1; display: flex; align-items: flex-start; overflow-x: auto; overflow-y: auto;
           padding: 10px 4px 20px 10px; position: relative; }
.lines { position: absolute; top: 0; left: 0; pointer-events: none; z-index: 1; }
.ocol { flex: none; width: 262px; display: flex; flex-direction: column; z-index: 2; }
.ocol + .ocol { border-left: 1px solid var(--line); padding-left: 12px; margin-left: 10px; }
.card { background: var(--panel2); border: 1px solid var(--line); border-radius: 9px;
        box-shadow: 0 2px 8px #0006; overflow: hidden; flex: none; }
.card.sel { border-color: var(--acc); }
.card.hall { border-color: var(--warn); }
.card .hd { display: flex; align-items: center; gap: 6px; padding: 5px 9px; height: 32px;
            border-bottom: 1px solid var(--line); font-weight: 600; font-size: 12px; cursor: pointer;
            white-space: nowrap; overflow: hidden; }
.card .hd:hover { background: #ffffff07; }
.card .hd .tier { color: var(--dim); font-size: 10.5px; font-weight: 400; }
.card .hd .sub { color: var(--dim); font-size: 10px; font-weight: 400; margin-left: auto; }
.card .hd .del { visibility: hidden; padding: 1px 7px; font-size: 10px; }
.card .hd:hover .del { visibility: visible; }
.srow { display: flex; align-items: center; gap: 5px; padding: 0 9px; height: 24px; border-radius: 5px;
        font-size: 11.5px; cursor: pointer; white-space: nowrap; overflow: hidden; }
.srow:hover { background: #ffffff08; }
.srow.sel { background: #4f8cff22; }
.srow.locked { opacity: .55; }
/* 岗位标签按用人类型分色：run 必需 · flex 借调 · any 弹性 · opt 增益 */
.srow .fn { flex: none; border-radius: 5px; padding: 1px 7px; font-size: 11px; }
.fn.p-run  { background: #59323f; color: #f0c0cd; }
.fn.p-flex { background: #595032; color: #f0e2bc; }
.fn.p-any  { background: #324059; color: #bcd0f5; }
.fn.p-opt  { background: #1f5c3e; color: #b8ecd0; }
.srow .cnt { color: var(--dim); }
.srow .par { color: var(--dim); font-size: 10.5px; margin-left: auto; overflow: hidden;
             text-overflow: ellipsis; }
.srow .need { color: var(--bad); font-size: 10.5px; }
.srow .wip { color: var(--flow); font-size: 10.5px; }
.sops { display: flex; align-items: center; gap: 5px; flex-wrap: wrap; padding: 4px 9px 6px;
        border-top: 1px dashed var(--line); background: #1a2030; font-size: 11px; }
.sops select { max-width: 108px; font-size: 11px; padding: 2px 4px; }
.sops button { padding: 2px 8px; font-size: 11px; }
.sops .cbtn.late { color: var(--dim); }
.sops .cbtn.late i { font-style: normal; font-size: 10px; color: var(--warn); margin-left: 3px; }
.sops .ohint { color: var(--faint); font-size: 10px; }
.sops .ohint.b { color: var(--acc); }
</style>
