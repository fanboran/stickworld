<script setup>
import { computed, ref, watch } from "vue";
import { S, ORG_PANELS, ARTS, circ, membersOf, delOrg, idle, feed, slotCandidates, createBlocked, startOrgTask } from "../sim.js";

/* 指令面板：各组织专属运行操作所在地（结构各异），实际游戏为定制精美 UI，sim 只模拟基础功能 */
const sel = computed(() => S.sel && !S.selSlot && S.orgs[S.sel] ? S.orgs[S.sel] : null);
const traineeId = computed({
  get: () => sel.value?.settings["受训组织"] || "",
  set: v => { if (sel.value) { sel.value.settings["受训组织"] = v;
    if (v) feed(`${sel.value.name} 接收 ${S.orgs[v].name} 整编制受训`, "good"); } },
});
const traineeOrg = computed(() => {
  const id = sel.value?.settings["受训组织"];
  return id && S.orgs[id] ? S.orgs[id] : null;
});
const panels = computed(() => sel.value ? (ORG_PANELS[sel.value.template] || []) : []);
/* 筹建任务行：本组织各槽的可构筑候选（槽有人=可下达；读条中=示进度） */
const foundRows = computed(() => {
  if (!sel.value) return [];
  const rows = [];
  for (const [fn, sl] of Object.entries(sel.value.slots)) {
    const cands = slotCandidates(fn).filter(nm => nm !== sel.value.template);
    if (sl.institution || !cands.length) continue;
    rows.push({ fn, cands, staffed: sl.persons.length > 0, task: S.orgTasks.find(t => t.c === sel.value.id && t.fn === fn) });
  }
  return rows;
});
/* 库存目标档位随仓库座数放大（基数 20/40/80/160 × 座数，仍取整十）——大库容下档位不再形同虚设；
   档值是绝对数：旧档存的「满40」在任何座数下含义不变 */
function choicesOf(org, opt) {
  if (opt.key !== "库存目标") return opt.choices;
  const k = S.buildings["仓库"]?.length || 1;
  return [["不限", opt.choices[0][1]],
    ...[20, 40, 80, 160].map(n => [`满${n * k}`,
      `产物库存≥${n * k} 歇线——满仓歇工、低于自动复工（军需式按需生产）`])];
}
function choose(org, opt, choice) { org.settings[opt.key] = choice; }
/* 选项可带实物前提 { need: 资源名 }：库中无此物则禁用——载具等耐用品的物理在场门槛 */
const lacks = c => c[2]?.need && S.res[c[2].need] < 1;
const curDesc = (org, opt) => choicesOf(org, opt).find(c => c[0] === org.settings[opt.key])?.[1] || "";
/* 训练目标（17 §二 落到个体）：属性+1 或 全员习得技能；目标技能教官须会 */
const ATTRS = [["str", "力量"], ["int", "智力"], ["agi", "敏捷"], ["cft", "灵巧"], ["cmd", "组织"]];
const goal = computed({
  get: () => sel.value?.settings["训练目标"] || "属性·cft",
  set: v => { if (sel.value) { sel.value.settings["训练目标"] = v; sel.value.trainProg = 0; feed(`${sel.value.name} 改训练目标：${v.replace("属性·", "").replace("技能·", "")}（进度重置）`, "warn"); } },
});
const goalOk = computed(() => {
  const g = goal.value;
  if (!g.startsWith("技能·")) return true;
  const camp = sel.value;
  return (camp?.slots["教官"].persons || []).some(pid => S.people.find(p => p.id === pid)?.skills.includes(g.slice(3)));
});
/* 待业名册（右侧栏空态）：一眼看清谁会什么——派工/构筑的前提情报 */
const roster = computed(() => idle().slice(0, 12));
const attrStr = p => ATTRS.map(([k, n]) => n + p.attr[k]).join(" ");
/* 解散两步确认（同 OrgCols askDel）：首点布防 2.5s，再点执行 */
const armed = ref("");
let armTimer = null;
function askDisband() {
  if (!sel.value) return;
  if (armed.value) { clearTimeout(armTimer); armed.value = ""; delOrg(sel.value.id); return; }
  armed.value = sel.value.id;
  clearTimeout(armTimer);
  armTimer = setTimeout(() => armed.value = "", 2500);
}
watch(sel, () => armed.value = "");
</script>

<template>
  <div id="orgpanel">
    <template v-if="sel">
      <div class="phead">
        {{ sel.name }}<span class="tier">L{{ sel.tier }}</span>
        <span class="sub">在编 {{ membersOf(sel) }}{{ sel.bldg ? " · 驻" + sel.bldg.b + circ(sel.bldg.idx) : (sel.bldgType ? " · 缺" + sel.bldgType : "") }}</span>
      </div>
      <div class="pnote">指令面板——各组织专属（结构各异），此处模拟基础功能</div>
      <!-- 筹建任务（裁决48）：命令槽内在编者读条建组织（完成转任主管，裁决47）；门槛＝槽内先有人 -->
      <div v-if="foundRows.length" class="opt">
        <div class="optkey">筹建任务（槽内在编者读条 3 时成编制）</div>
        <div v-for="row in foundRows" :key="row.fn" class="trow">
          <span class="tf">{{ row.fn }}：</span>
          <template v-if="row.task">
            <span class="tprog">筹建{{ row.task.name }} {{ Math.floor(100 * row.task.prog / row.task.need) }}%</span>
          </template>
          <template v-else>
            <button v-for="nm in row.cands" :key="nm"
                    :disabled="!row.staffed || !!createBlocked(nm)"
                    :title="(createBlocked(nm) || (row.staffed ? nm + '——读条 3 时建成，经办人转任主管' : '槽内先放人（点击槽自动派最合适的待业者）'))"
                    @click="startOrgTask(sel.id, row.fn, nm)">＋{{ nm }}</button>
            <span v-if="!row.staffed" class="ohint">槽内先放人</span>
          </template>
        </div>
      </div>
      <!-- 训练营：受训组织选择与训练进度（04 §三 组织对组织） -->
      <div v-if="sel.template === '训练营'" class="opt">
        <div class="optkey">受训组织（整只编制开过来受训）</div>
        <select v-model="traineeId">
          <option value="">选择编制组织…</option>
          <option v-for="x in S.order.filter(y => y !== sel.id && S.orgs[y] && S.orgs[y].kind !== 'hall' && S.orgs[y].template !== '训练营')"
                  :key="x" :value="x">{{ S.orgs[x].name }}（在编 {{ membersOf(S.orgs[x]) }}）</option>
        </select>
        <div class="optdesc">
          教官 {{ sel.slots["教官"].persons.length }} 人在编 · 速率 {{ 4 * sel.slots["教官"].persons.length }} 点/时
          （100 点一结业；无教官停摆进度不丢）
        </div>
        <div class="optkey">训练目标（结业落到每名在编身上）</div>
        <select v-model="goal">
          <optgroup label="属性 +1（钳 0~10）">
            <option v-for="[k, n] of ATTRS" :key="k" :value="'属性·' + k">{{ n }} +1</option>
          </optgroup>
          <optgroup label="技能（全员习得；教官须会）">
            <option v-for="a of ARTS" :key="a" :value="'技能·' + a">{{ a }}</option>
          </optgroup>
        </select>
        <div class="optdesc" :class="{ bad: !goalOk }">
          {{ goalOk ? "目标可行" : "教官无人会该技能——不会的教不了，先换教官或改目标" }}
        </div>
        <template v-if="traineeOrg">
          <div class="trainrow">
            <span>{{ traineeOrg.name }} · 训练{{ ["Ⅰ","Ⅱ","Ⅲ","Ⅳ","Ⅴ","Ⅵ","Ⅶ","Ⅷ"][traineeOrg.trainLv - 1] || "—" }}</span>
            <div class="bar"><i :style="{ width: traineeOrg.trainProg + '%' }"></i></div>
            <span class="dim">{{ Math.floor(traineeOrg.trainProg) }}%</span>
          </div>
        </template>
      </div>
      <!-- 受训等级呈报（任何有等级的组织都显示） -->
      <div v-if="sel.trainLv" class="optdesc">受训等级：训练{{ ["Ⅰ","Ⅱ","Ⅲ","Ⅳ","Ⅴ","Ⅵ","Ⅶ","Ⅷ"][sel.trainLv - 1] }}（继续受训在训练营面板发起）</div>
      <div v-for="opt in panels" :key="opt.key" class="opt">
        <div class="optkey">{{ opt.key }}</div>
        <div class="optbtns">
          <button v-for="c in choicesOf(sel, opt)" :key="c[0]"
                  :class="{ on: sel.settings[opt.key] === c[0] }"
                  :disabled="lacks(c)"
                  :title="c[1] + (lacks(c) ? '｜库中无' + c[2].need + '，先让木器坊出一辆' : '')"
                  @click="choose(sel, opt, c[0])">{{ c[0] }}</button>
        </div>
        <div class="optdesc">{{ curDesc(sel, opt) }}</div>
      </div>
      <div v-if="!panels.length" class="pnote dim">该组织暂无面板选项（随机制补）</div>
      <button v-if="sel.kind !== 'hall'" class="warn dis" @click="askDisband()">{{ armed === sel.id ? "再点一次——确认解散" : "解散组织（人员回待业）" }}</button>
    </template>
    <div v-else class="roster">
      <div class="pnote">点组织卡片头部打开它的指令面板；下面是待业名册——派工与构筑前先看谁会什么</div>
      <div v-for="p in roster" :key="p.id" class="rrow" :title="attrStr(p) + (p.skills.length ? '｜会 ' + p.skills.join('、') : '｜无技艺') + '｜已闲置 ' + Math.floor(p.idleT || 0) + ' 时（村民闲置满 72 时离乡）'">
        <div class="rline1"><b>{{ p.name }}</b><span class="rattr">{{ attrStr(p) }}</span></div>
        <div class="rart" v-if="p.skills.length">会{{ p.skills.join("/") }}</div>
      </div>
      <div v-if="!roster.length" class="pnote dim">无待业者</div>
      <div v-if="idle().length > roster.length" class="pnote dim">…另有 {{ idle().length - roster.length }} 人</div>
    </div>
  </div>
</template>

<style scoped>
#orgpanel { flex: none; max-height: 46%; overflow-y: auto; border-bottom: 1px solid var(--line);
            padding: 8px 10px; }
.phead { font-weight: 700; font-size: 13px; display: flex; align-items: baseline; gap: 6px; }
.phead .tier { color: var(--dim); font-size: 10.5px; font-weight: 400; }
.phead .sub { color: var(--dim); font-size: 10.5px; font-weight: 400; margin-left: auto; }
.pnote { color: var(--dim); font-size: 10.5px; margin: 4px 0 6px; }
.pnote.dim { color: var(--faint); margin: 8px 0; }
.opt { margin: 7px 0; }
.optkey { font-size: 11.5px; color: var(--fg); font-weight: 600; margin-bottom: 3px; }
.optbtns { display: flex; gap: 4px; flex-wrap: wrap; }
.optbtns button { font-size: 11px; padding: 2px 9px; }
.optbtns button.on { background: #2c4d8f; border-color: #4368b8; color: #fff; }
.optdesc { color: var(--dim); font-size: 10.5px; margin-top: 3px; }
.opt select { max-width: 150px; font-size: 11px; }
.trainrow { display: flex; align-items: center; gap: 6px; margin-top: 5px; font-size: 11.5px; }
.trainrow .bar { flex: 1; }
.dim { color: var(--dim); font-size: 10.5px; font-variant-numeric: tabular-nums; }
.optdesc.bad { color: var(--bad); }
.roster .rrow { padding: 4px 0 3px; font-size: 11px; border-bottom: 1px dashed var(--line); }
.roster .rline1 { display: flex; align-items: baseline; gap: 6px; }
.roster .rrow b { flex: none; }
.roster .rattr { color: var(--faint); font-size: 10px; font-variant-numeric: tabular-nums; }
.roster .rart { color: var(--flow); font-size: 10px; margin-top: 1px; }
.dis { width: 100%; margin-top: 8px; }
.trow { display: flex; align-items: center; gap: 5px; flex-wrap: wrap; margin: 3px 0; }
.trow .tf { font-size: 11px; color: var(--dim); min-width: 52px; }
.trow .tprog { font-size: 11px; color: var(--acc); font-variant-numeric: tabular-nums; }
.trow .ohint { font-size: 10px; color: var(--faint); }
</style>
