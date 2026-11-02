<script setup>
import { computed, ref } from "vue";
import { S, ORGS, CIRC, person, membersOf, wipOf, orgEquip, stepDesc, slotProduct,
         idle, select, delOrg, feed, slotCandidates, createBlocked, slotCap,
         putPerson, pullPersons, createOrgAt } from "../sim.js";

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

/* ── 列＝深度，列内按「父卡槽序」排列：连线起点序＝落点序，兄弟线天然不交叉 ── */
const columns = computed(() => {
  const byDepth = {};
  for (const id of S.order) {
    if (!S.orgs[id]) continue;
    (byDepth[depthOf(id)] ||= []).push(id);
  }
  const maxD = Math.max(...Object.keys(byDepth).map(Number));
  const cols = [];
  let prevSorted = [];
  for (let d = 0; d <= maxD; d++) {
    let ids = byDepth[d] || [];
    if (d > 0) {
      const key = {};
      for (const id of ids) {
        const h = host.value[id];   // { org: 父id, fn: 入驻槽名 }
        if (!h) { key[id] = 1e9; continue; }
        key[id] = prevSorted.indexOf(h.org) * 1000 +
                  Object.keys(S.orgs[h.org].slots).indexOf(h.fn);
      }
      ids = [...ids].sort((a, b) =>
        (key[a] - key[b]) || (S.order.indexOf(a) - S.order.indexOf(b)));
    }
    prevSorted = ids;
    cols.push({ orgs: ids.map(x => S.orgs[x]) });
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
const POS_NAME = { must: "必须：至少一人该组织才能开工", semi: "半必须：需人运行，可移调顶岗", gain: "增益：无人也行，只是缺该功能" };

</script>

<template>
  <div id="orgCols">
    <div class="ocol" v-for="(col, ci) in columns" :key="ci">
      <div v-for="o in col.orgs" :key="o.id" class="card" :data-org="o.id"
           :class="{ hall: o.kind === 'hall', sel: S.sel === o.id && !S.selSlot }">
        <div class="hd" @click="select(o.id)">
          <span>{{ o.name }}</span><span class="tier">L{{ o.tier }}</span><span v-if="o.trainLv" class="tier">训{{ ["Ⅰ","Ⅱ","Ⅲ","Ⅳ","Ⅴ","Ⅵ","Ⅶ","Ⅷ"][o.trainLv - 1] }}</span>
          <span class="sub">{{ o.kind === "hall" ? "根节点" :
            (host[o.id] ? "入驻·" + host[o.id].fn + "槽" : "未入驻") }}{{ o.bldgType
              ? (o.bldg ? " · 驻" + o.bldg.b + CIRC[o.bldg.idx] : " · 缺" + o.bldgType)
              : "" }} · 在编 {{ membersOf(o) }}</span>
          <button v-if="o.kind !== 'hall'" class="del warn" title="解散组织（人员回待业）"
                  @click.stop="delOrg(o.id)">×</button>
        </div>
        <div v-for="(slot, fn) in o.slots" :key="fn" class="slotwrap">
          <div class="srow"
               :class="{ locked: isLocked(o, slot), sel: S.sel === o.id && S.selSlot === fn }"
               @click="clickSlot(o, fn, slot)">
            <span class="fn" :class="'p-' + (slot.def.pos || 'run')"
                  :title="POS_NAME[slot.def.pos || 'run'] + '｜' + (slot.def.role || '')">{{ fn }}</span>
            <span v-if="slot.def.homog" class="cnt">{{ slot.persons.length }}/{{ slotCap(o, slot) }}</span>
            <template v-if="slot.persons.length || slot.institution">
              <span v-for="c in chipsOf(slot)" :key="c" class="chip">{{ c }}</span>
              <span v-if="slot.institution" class="chip orgchip">{{ S.orgs[slot.institution]?.name || "?" }}</span>
            </template>
            <span v-else class="chip empty">空槽</span>
            <!-- 移调动效：目标槽半透明人名+慢速圈 -->
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
              <template v-if="slot.def.terrain">{{ slot.def.terrain }}·{{ slotProduct(slot) }}</template>
              <template v-else-if="slot.def.step !== undefined && o.steps[slot.def.step]">{{ stepDesc(o.steps[slot.def.step]) }}</template>
              <template v-else-if="slot.def.role">{{ slot.def.role.slice(0, 14) }}</template>
            </span>
          </div>
          <!-- 槽位操作内联：构筑子组织（递归）/ 派人 -->
          <div v-if="opsOpen(o, fn, slot)" class="sops" @click.stop>
            <template v-if="emptySlot(slot) && slotCandidates(fn).length">
              <span class="ohint b">构筑：</span>
              <button v-for="name in slotCandidates(fn).filter(x => x !== o.template)" :key="name" class="cbtn"
                      :class="{ late: ORGS[name].late }" :disabled="!!createBlocked(name)"
                      :title="candTitle(name)"
                      @click="createOrgAt(o.id, fn, name)">＋{{ name }}<i v-if="ORGS[name].late">后期</i></button>
            </template>
            <select v-model="pickPerson" :disabled="slot.def.homog && slot.persons.length >= slotCap(o, slot)">
              <option value="">{{ slot.def.homog && slot.persons.length >= slotCap(o, slot) ? "坑位已满" : "待业人员…" }}</option>
              <option v-for="p in idle()" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
            <button :disabled="!pickPerson" @click="putPerson(o.id, fn, pickPerson); pickPerson = ''">派入</button>
            <button v-if="slot.persons.length" @click="pullPersons(o.id, fn)">撤出全部</button>
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
.ocol { flex: none; width: 262px; display: flex; flex-direction: column; gap: 10px; z-index: 2; }
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
.srow .fn { flex: none; border-radius: 5px; padding: 1px 7px; font-size: 11px; }
.fn.p-must { background: #59323f; color: #f0c0cd; }
.fn.p-semi { background: #595032; color: #f0e2bc; }
.fn.p-gain { background: #1f5c3e; color: #b8ecd0; }
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
