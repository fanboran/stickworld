<script setup>
import { computed, ref } from "vue";
import { S, TERRAIN, idle, feed } from "../sim.js";
import OrgCols from "./OrgCols.vue";
import BuildSide from "./BuildSide.vue";
import OrgPanel from "./OrgPanel.vue";

/* 地形条：各采集场的场地堆存（缓冲堆，待运输队搬运） */
const terrainRows = computed(() => Object.entries(TERRAIN).map(([site, t]) => {
  const parts = t.products.map(p => ({ p, v: S.buf[site + "|" + p] || 0 }));
  const fill = Math.max(...parts.map(x => x.v / S.knobs.buf));
  return { site, parts, fill };
}));
const staffed = computed(() => S.people.length - idle().length);
/* 耕战一体：动员官在编才能动员；战备=全体产率减半 */
const milStaffed = computed(() => Object.values(S.orgs).some(o =>
  o.template === "常备军" ? o.slots["军事"].persons.length > 0 : false) ||
  (S.orgs.o01 && S.orgs.o01.slots["军事"].persons.length > 0));
const militia = computed(() => S.mobilized ? S.people.filter(p => p.name.startsWith("村民")).length : 0);
function toggleMob() {
  if (S.mobilized) { S.mobilized = false; feed("解除动员，回到生产", "good"); }
  else { S.mobilized = true; feed("动员令下：转入战备，产率减半", "warn"); }
}
</script>

<template>
  <div id="orgpage">
    <div id="otool">
      <div class="tgroup">
        <div v-for="t in terrainRows" :key="t.site" class="tchip" :class="{ full: t.fill >= 1 }"
             :title="`采集产出先堆在采集场（待运输队搬回仓库）；堆满 ${S.knobs.buf} 则停采`">
          <span class="nm">{{ t.site }}</span>
          <span class="piles">
            <span v-for="x in t.parts" :key="x.p" class="pile">待运 {{ x.v.toFixed(0) }}/{{ S.knobs.buf }}</span>
          </span>
          <div class="bar tb"><i :class="{ mid: t.fill >= .8, full: t.fill >= 1 }"
               :style="{ width: Math.min(100, t.fill * 100) + '%' }"></i></div>
        </div>
      </div>
      <div class="oright">
        <span class="legend" title="岗位标签按用人类型分色">
          <i class="lg p-must" /><span>必须</span>
          <i class="lg p-semi" /><span>半必须</span>
          <i class="lg p-gain" /><span>增益</span>
        </span>
        <span class="popu" title="在编=挂在各组织槽上；待业=可派">在编 {{ staffed }} · 待业 {{ idle().length }}</span>
        <button class="mob" :class="{ war: S.mobilized }" :disabled="!milStaffed"
                :title="milStaffed ? '耕战一体：平时生产、战时皆兵（战备产率减半）' : '需动员官在编（市政厅军事槽或常备军军事槽）'"
                @click="toggleMob">
          {{ S.mobilized ? `战备中·民兵${militia}，解除` : "动员" }}
        </button>
      </div>
    </div>
    <div id="obody">
      <OrgCols />
      <div id="rightcol">
        <OrgPanel />
        <BuildSide />
      </div>
    </div>
  </div>
</template>

<style scoped>
#orgpage { flex: 1; display: flex; flex-direction: column; min-height: 0; }
#otool { display: flex; align-items: center; gap: 14px; padding: 7px 14px; flex-wrap: wrap;
         border-bottom: 1px solid var(--line); background: #131826; flex: none; }
.tgroup { display: flex; gap: 7px; }
.tchip { width: 136px; background: var(--panel2); border: 1px solid var(--line);
         border-radius: 8px; padding: 4px 8px; font-size: 11px; }
.tchip .nm { color: var(--dim); margin-right: 4px; }
.tchip .pile { color: var(--fg); margin-right: 6px; font-variant-numeric: tabular-nums; }
.tchip .tb { margin-top: 3px; }
.tchip.full { border-color: var(--bad); }
.oright { display: flex; align-items: center; gap: 10px; margin-left: auto; }
.legend { display: inline-flex; align-items: center; gap: 4px; color: var(--dim); font-size: 10.5px; }
.legend .lg { width: 9px; height: 9px; border-radius: 3px; display: inline-block; margin-left: 5px; }
.legend .lg:first-child { margin-left: 0; }
.lg.p-must { background: #8a4a55; }
.lg.p-semi { background: #8a7640; }
.lg.p-gain { background: #3a7a5a; }
.popu { color: var(--dim); font-size: 11.5px; white-space: nowrap; }
#rightcol { width: 248px; flex: none; display: flex; flex-direction: column;
            background: var(--panel); border-left: 1px solid var(--line); min-height: 0; }
.mob.war { background: #5c441f; border-color: var(--warn); color: var(--warn); }
#obody { flex: 1; display: flex; min-height: 0; }
</style>
