<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { S, ORGS, TERRAIN, CIRC, person, membersOf, wipOf, orgEquip, stepDesc, slotProduct,
         idle, select, delOrg, feed, slotCandidates, createBlocked,
         putPerson, pullPersons, putOrg, pullOrg, setProduct, createOrgAt } from "../sim.js";

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
const columns = computed(() => {
  const byDepth = {};
  for (const id of S.order) {
    if (!S.orgs[id]) continue;
    (byDepth[depthOf(id)] ||= []).push(S.orgs[id]);
  }
  const maxD = Math.max(...Object.keys(byDepth).map(Number));
  const cols = [];
  for (let d = 0; d <= maxD; d++)
    cols.push({ orgs: byDepth[d] || [], depth: d });
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
  pickPerson.value = ""; pickOrg.value = "";
  select(o.id, fn);
}
const opsOpen = (o, fn, slot) => S.sel === o.id && S.selSlot === fn && !isLocked(o, slot);
const pickPerson = ref("");
const pickOrg = ref("");
const emptySlot = slot => !slot.persons.length && !slot.institution;
function candTitle(name) {
  const t = ORGS[name];
  const desc = t.steps && t.steps.length ? t.steps.map(stepDesc).join("→")
    : (t.slots || []).map(s => s.fn + (s.homog ? "×" + s.n : "")).join("/");
  const blocked = createBlocked(name);
  return desc + (blocked ? "｜" + blocked : "");
}

/* ── 嵌套连线：机构入驻槽 → 子组织卡片（SVG 覆盖层，肘形线） ── */
const svg = ref(null);
const linesKey = computed(() => Object.values(S.orgs).map(o =>
  o.id + ":" + Object.values(o.slots).map(s => s.institution).join(",")).join(";"));
function drawLines() {
  const root = document.getElementById("orgCols");
  if (!root || !svg.value) return;
  const c = root.getBoundingClientRect();
  const pt = r => ({ x: r.left - c.left + root.scrollLeft, y: r.top - c.top + root.scrollTop });
  const d = [];
  for (const o of Object.values(S.orgs))
    for (const [fn, slot] of Object.entries(o.slots)) {
      if (!slot.institution || !S.orgs[slot.institution]) continue;
      const from = root.querySelector(`[data-slot="${o.id}|${fn}"]`);
      const to = root.querySelector(`[data-org="${slot.institution}"]`);
      if (!from || !to) continue;
      const a = pt(from.getBoundingClientRect());
      const b = pt(to.getBoundingClientRect());
      const x1 = a.x + from.getBoundingClientRect().width, y1 = a.y + from.getBoundingClientRect().height / 2;
      const x2 = b.x, y2 = b.y + 14;   // 卡片头部高度处接入
      const xm = x1 + 10;
      d.push(`M${x1},${y1} H${xm} V${y2} H${x2}`);
    }
  svg.value.setAttribute("width", Math.max(root.scrollWidth, c.width));
  svg.value.setAttribute("height", Math.max(root.scrollHeight, c.height));
  svg.value.innerHTML = d.map(p =>
    `<path d="${p}" fill="none" stroke="#e359c4" stroke-opacity=".55" stroke-width="1.5"/>`).join("");
}
watch(linesKey, () => nextTick(drawLines), { flush: "post" });
watch(columns, () => nextTick(drawLines), { flush: "post" });
onMounted(() => {
  nextTick(drawLines);
  window.addEventListener("resize", drawLines);
});
onUnmounted(() => window.removeEventListener("resize", drawLines));
</script>

<template>
  <div id="orgCols">
    <svg ref="svg" class="lines"></svg>
    <div class="ocol" v-for="col in columns" :key="col.depth">
      <div v-for="o in col.orgs" :key="o.id" class="card" :data-org="o.id"
           :class="{ hall: o.kind === 'hall', sel: S.sel === o.id && !S.selSlot }">
        <div class="hd" @click="select(o.id)">
          <span>{{ o.name }}</span><span class="tier">L{{ o.tier }}</span>
          <span class="sub">{{ o.kind === "hall" ? "根节点" :
            (host[o.id] ? "入驻·" + host[o.id].fn + "槽" : "未入驻") }}{{ o.bldgType
              ? (o.bldg ? " · 驻" + o.bldg.b + CIRC[o.bldg.idx] : " · 缺" + o.bldgType)
              : "" }} · 在编 {{ membersOf(o) }}</span>
          <button v-if="o.kind !== 'hall'" class="del warn" title="解散组织（人员回待业）"
                  @click.stop="delOrg(o.id)">×</button>
        </div>
        <div v-for="(slot, fn) in o.slots" :key="fn" class="slotwrap">
          <div class="srow" :data-slot="o.id + '|' + fn"
               :class="{ locked: isLocked(o, slot), sel: S.sel === o.id && S.selSlot === fn }"
               @click="clickSlot(o, fn, slot)">
            <span class="fn" :class="{ hall: fn === '市长', mil: ['军事','训练'].includes(fn) }">{{ fn }}</span>
            <span v-if="slot.def.homog" class="cnt">{{ slot.persons.length }}/{{ slot.def.n }}</span>
            <template v-if="slot.persons.length || slot.institution">
              <span v-for="c in chipsOf(slot)" :key="c" class="chip">{{ c }}</span>
              <span v-if="slot.institution" class="chip orgchip">机构·{{ S.orgs[slot.institution]?.name || "?" }}</span>
            </template>
            <span v-else class="chip empty">空槽</span>
            <!-- 借调动效：目标槽半透明人名+慢速圈 -->
            <span v-for="(b, i) in borrowsOf(o.id).filter(x => x.to === fn)" :key="'g' + i" class="ghostbox">
              <span>{{ chipName(o.slots[b.from]?.persons[0]) }}↦</span><span class="spin"></span>
            </span>
            <span v-if="slot.def.step !== undefined && o.steps[slot.def.step]?.wip" class="wip">
              {{ o.steps[slot.def.step].wip }} {{ (wipOf(o)[o.steps[slot.def.step].wip] || 0).toFixed(1) }}
            </span>
            <span v-if="slot.persons.length" class="spin"
                  :class="{ paused: borrowsOf(o.id).filter(x => x.from === fn).length >= slot.persons.length }"></span>
            <span v-if="isLocked(o, slot)" class="need">
              需{{ slot.def.req.b }}{{ slot.def.req.item ? "·" + slot.def.req.item : "" }}
            </span>
            <span class="par">
              <template v-if="slot.def.terrain">{{ slot.def.terrain }}{{ slot.product ? "·" + slotProduct(slot) : "" }}</template>
              <template v-else-if="slot.def.step !== undefined && o.steps[slot.def.step]">{{ stepDesc(o.steps[slot.def.step]) }}</template>
              <template v-else-if="slot.def.role">{{ slot.def.role.slice(0, 16) }}</template>
            </span>
          </div>
          <!-- 槽位操作内联：派人 / 构筑子组织（递归）/ 塞已有机构 / 选产物 -->
          <div v-if="opsOpen(o, fn, slot)" class="sops" @click.stop>
            <template v-if="emptySlot(slot) && slotCandidates(fn).length">
              <span class="ohint b">构筑：</span>
              <button v-for="name in slotCandidates(fn)" :key="name" class="cbtn"
                      :class="{ late: ORGS[name].late }" :disabled="!!createBlocked(name)"
                      :title="candTitle(name)"
                      @click="createOrgAt(o.id, fn, name)">＋{{ name }}<i v-if="ORGS[name].late">后期</i></button>
            </template>
            <select v-model="pickPerson" :disabled="slot.def.homog && slot.persons.length >= slot.def.n">
              <option value="">{{ slot.def.homog && slot.persons.length >= slot.def.n ? "坑位已满" : "待业人员…" }}</option>
              <option v-for="p in idle()" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
            <button :disabled="!pickPerson" @click="putPerson(o.id, fn, pickPerson); pickPerson = ''">派入</button>
            <button v-if="slot.persons.length" @click="pullPersons(o.id, fn)">撤出全部</button>
            <select v-model="pickOrg">
              <option value="">塞已有组织…</option>
              <option v-for="x in S.order.filter(y => y !== o.id && S.orgs[y])" :key="x" :value="x">
                {{ S.orgs[x].name }}
              </option>
            </select>
            <button :disabled="!pickOrg" @click="putOrg(o.id, fn, pickOrg); pickOrg = ''">塞机构</button>
            <button v-if="slot.institution" @click="pullOrg(o.id, fn)">撤机构</button>
            <select v-if="TERRAIN[slot.def.terrain] && TERRAIN[slot.def.terrain].products.length > 1"
                    :value="slotProduct(slot)" title="选产物"
                    @change="setProduct(o.id, fn, $event.target.value)">
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
.ocol { flex: none; width: 262px; display: flex; flex-direction: column; gap: 8px; z-index: 2; }
.ocol + .ocol { border-left: 1px solid var(--line); padding-left: 12px; margin-left: 10px; }
.card { background: var(--panel2); border: 1px solid var(--line); border-radius: 9px;
        box-shadow: 0 2px 8px #0006; overflow: hidden; }
.card.sel { border-color: var(--acc); }
.card.hall { border-color: var(--warn); }
.card .hd { display: flex; align-items: center; gap: 6px; padding: 5px 9px;
            border-bottom: 1px solid var(--line); font-weight: 600; font-size: 12px; cursor: pointer; }
.card .hd:hover { background: #ffffff07; }
.card .hd .tier { color: var(--dim); font-size: 10.5px; font-weight: 400; }
.card .hd .sub { color: var(--dim); font-size: 10px; font-weight: 400; margin-left: auto; }
.card .hd .del { visibility: hidden; padding: 1px 7px; font-size: 10px; }
.card .hd:hover .del { visibility: visible; }
.srow { display: flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 5px;
        font-size: 11.5px; min-height: 23px; cursor: pointer; flex-wrap: wrap; }
.srow:hover { background: #ffffff08; }
.srow.sel { background: #4f8cff22; }
.srow.locked { opacity: .55; }
.srow .fn { flex: none; background: #324059; border-radius: 5px; padding: 1px 7px;
            color: #bcd0f5; font-size: 11px; }
.srow .fn.mil { background: #59323f; color: #f0c0cd; }
.srow .fn.hall { background: #595032; color: #f0e2bc; }
.srow .cnt { color: var(--dim); }
.srow .par { color: var(--dim); font-size: 10.5px; margin-left: auto; }
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
