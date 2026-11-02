<script setup>
import { computed } from "vue";
import { S, ORG_PANELS, CIRC, membersOf, delOrg } from "../sim.js";

/* 指令面板：各组织专属运行操作所在地（结构各异），实际游戏为定制精美 UI，sim 只模拟基础功能 */
const sel = computed(() => S.sel && !S.selSlot && S.orgs[S.sel] ? S.orgs[S.sel] : null);
const panels = computed(() => sel.value ? (ORG_PANELS[sel.value.template] || []) : []);
function choose(org, opt, choice) { org.settings[opt.key] = choice; }
/* 选项可带实物前提 { need: 资源名 }：库中无此物则禁用——载具等耐用品的物理在场门槛 */
const lacks = c => c[2]?.need && S.res[c[2].need] < 1;
const curDesc = (org, opt) => opt.choices.find(c => c[0] === org.settings[opt.key])?.[1] || "";
</script>

<template>
  <div id="orgpanel">
    <template v-if="sel">
      <div class="phead">
        {{ sel.name }}<span class="tier">L{{ sel.tier }}</span>
        <span class="sub">在编 {{ membersOf(sel) }}{{ sel.bldg ? " · 驻" + sel.bldg.b + CIRC[sel.bldg.idx] : (sel.bldgType ? " · 缺" + sel.bldgType : "") }}</span>
      </div>
      <div class="pnote">指令面板——各组织专属（结构各异），此处模拟基础功能</div>
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
      <button v-if="sel.kind !== 'hall'" class="warn dis" @click="delOrg(sel.id)">解散组织（人员回待业）</button>
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
.dis { width: 100%; margin-top: 8px; }
</style>
