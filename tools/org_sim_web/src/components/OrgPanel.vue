<script setup>
import { computed } from "vue";
import { S, ORG_PANELS, CIRC, membersOf, setProduct, delOrg } from "../sim.js";

/* 组织控制面板：实际游戏里是各组织专属的复杂精美 UI（结构各异），sim 只在侧栏模拟基础功能 */
const sel = computed(() => S.sel && !S.selSlot && S.orgs[S.sel] ? S.orgs[S.sel] : null);
const panels = computed(() => sel.value ? (ORG_PANELS[sel.value.template] || []) : []);
function choose(org, opt, choice) {
  org.settings[opt.key] = choice;
  if (opt.key === "产物") setProduct(org.id, "耕作", choice);   // 农垦队产物落到耕作槽
}
const curDesc = (org, opt) => opt.choices.find(c => c[0] === org.settings[opt.key])?.[1] || "";
</script>

<template>
  <div id="orgpanel">
    <template v-if="sel">
      <div class="phead">
        {{ sel.name }}<span class="tier">L{{ sel.tier }}</span>
        <span class="sub">在编 {{ membersOf(sel) }}{{ sel.bldg ? " · 驻" + sel.bldg.b + CIRC[sel.bldg.idx] : (sel.bldgType ? " · 缺" + sel.bldgType : "") }}</span>
      </div>
      <div class="pnote">组织控制面板——各组织专属（结构各异），此处模拟基础功能</div>
      <div v-for="opt in panels" :key="opt.key" class="opt">
        <div class="optkey">{{ opt.key }}</div>
        <div class="optbtns">
          <button v-for="[choice, desc] in opt.choices" :key="choice"
                  :class="{ on: sel.settings[opt.key] === choice }" :title="desc"
                  @click="choose(sel, opt, choice)">{{ choice }}</button>
        </div>
        <div class="optdesc">{{ curDesc(sel, opt) }}</div>
      </div>
      <div v-if="!panels.length" class="pnote dim">该组织暂无面板选项（随机制补）</div>
      <button v-if="sel.kind !== 'hall'" class="warn dis" @click="delOrg(sel.id)">解散组织（人员回待业）</button>
    </template>
    <div v-else class="pnote dim">点组织卡片头部，打开它的控制面板</div>
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
