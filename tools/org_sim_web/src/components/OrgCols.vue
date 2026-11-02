<script setup>
import { computed, ref } from "vue";
import { S, TERRAIN, person, membersOf, wipOf, equipOK, stepDesc, slotProduct,
         idle, select, delOrg, feed,
         putPerson, pullPersons, putOrg, pullOrg, setProduct } from "../sim.js";

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
  const names = ["市政厅", "下辖机构", "再下沉", "更深层"];
  const maxD = Math.max(...Object.keys(byDepth).map(Number));
  const cols = [];
  for (let d = 0; d <= maxD; d++)
    cols.push({ title: names[Math.min(d, names.length - 1)], orgs: byDepth[d] || [], depth: d });
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
const isLocked = slot => !!(slot.def.req && !equipOK(slot.def.req.b, slot.def.req.item));
function clickSlot(o, fn, slot) {
  if (isLocked(slot)) {
    const d = slot.def;
    feed(`${fn} 槽被禁：需 ${d.req.b}${d.req.item ? " 并装 " + d.req.item : ""}（组织无建筑仍可基础运转）`, "bad");
    return;
  }
  if (S.sel === o.id && S.selSlot === fn) { select(o.id, null); return; }   // 再点收起
  pickPerson.value = ""; pickOrg.value = "";
  select(o.id, fn);
}
const opsOpen = (o, fn, slot) => S.sel === o.id && S.selSlot === fn && !isLocked(slot);
const pickPerson = ref("");
const pickOrg = ref("");
</script>

<template>
  <div id="orgCols">
    <div class="ocol" v-for="col in columns" :key="col.depth">
      <h4>{{ col.title }}{{ col.depth > 0 ? `（${col.orgs.length}）` : "" }}</h4>
      <div v-for="o in col.orgs" :key="o.id" class="card"
           :class="{ hall: o.kind === 'hall', sel: S.sel === o.id && !S.selSlot }">
        <div class="hd" @click="select(o.id)">
          <span>{{ o.name }}</span><span class="tier">L{{ o.tier }}</span>
          <span class="sub">{{ o.kind === "hall" ? "根节点" :
            (host[o.id] ? "入驻·" + host[o.id].fn + "槽" : "未入驻") }} · 在编 {{ membersOf(o) }}</span>
          <button v-if="o.kind !== 'hall'" class="del warn" title="解散组织（人员回待业）"
                  @click.stop="delOrg(o.id)">×</button>
        </div>
        <div v-for="(slot, fn) in o.slots" :key="fn" class="slotwrap">
          <div class="srow" :class="{ locked: isLocked(slot), sel: S.sel === o.id && S.selSlot === fn }"
               @click="clickSlot(o, fn, slot)">
            <span class="fn" :class="{ hall: ['领导','行政'].includes(fn),
                                       mil: ['军事','训练'].includes(fn) }">{{ fn }}</span>
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
            <span v-if="isLocked(slot)" class="need">
              需{{ slot.def.req.b }}{{ slot.def.req.item ? "·" + slot.def.req.item : "" }}
            </span>
            <span class="par">
              <template v-if="slot.def.terrain">{{ slot.def.terrain }}{{ slot.product ? "·" + slotProduct(slot) : "" }}</template>
              <template v-else-if="slot.def.step !== undefined && o.steps[slot.def.step]">{{ stepDesc(o.steps[slot.def.step]) }}</template>
              <template v-else-if="slot.def.role">{{ slot.def.role.slice(0, 16) }}</template>
            </span>
          </div>
          <!-- 槽位操作内联：就地在所选槽行下方展开（不再放远端面板） -->
          <div v-if="opsOpen(o, fn, slot)" class="sops" @click.stop>
            <select v-model="pickPerson" :disabled="slot.def.homog && slot.persons.length >= slot.def.n">
              <option value="">{{ slot.def.homog && slot.persons.length >= slot.def.n ? "坑位已满" : "待业人员…" }}</option>
              <option v-for="p in idle()" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
            <button :disabled="!pickPerson" @click="putPerson(o.id, fn, pickPerson); pickPerson = ''">派入</button>
            <button v-if="slot.persons.length" @click="pullPersons(o.id, fn)">撤出全部</button>
            <select v-model="pickOrg">
              <option value="">塞组织为机构…</option>
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
            <span class="ohint">{{ slot.def.homog ? `同质化×${slot.def.n}，坑位随建筑规模` :
              (slot.def.role || "") }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
#orgCols { flex: 1; display: flex; gap: 12px; align-items: flex-start;
           overflow-x: auto; overflow-y: auto; padding: 10px 14px 20px; }
.ocol { flex: none; width: 276px; display: flex; flex-direction: column; gap: 8px; }
.ocol > h4 { font-size: 11px; color: var(--dim); font-weight: 600; margin: 0 0 -2px; }
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
.sops .ohint { color: var(--faint); font-size: 10px; }
</style>
