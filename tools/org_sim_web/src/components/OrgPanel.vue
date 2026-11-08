<script setup>
import { computed, ref, watch } from "vue";
import { S, ORG_PANELS, circ, membersOf, delOrg } from "../sim.js";

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
function choose(org, opt, choice) { org.settings[opt.key] = choice; }
/* 选项可带实物前提 { need: 资源名 }：库中无此物则禁用——载具等耐用品的物理在场门槛 */
const lacks = c => c[2]?.need && S.res[c[2].need] < 1;
const curDesc = (org, opt) => opt.choices.find(c => c[0] === org.settings[opt.key])?.[1] || "";
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
          （100 点升 1 级；无教官停摆进度不丢）
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
          <button v-for="c in opt.choices" :key="c[0]"
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
    <div v-else class="pnote dim">点组织卡片头部，打开它的指令面板</div>
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
.dis { width: 100%; margin-top: 8px; }
</style>
