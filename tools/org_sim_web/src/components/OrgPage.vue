<script setup>
import { computed, ref } from "vue";
import { S, TERRAIN, ORGS, ORG_CATS, LATE_COST, idle, orgDesc, costStr, canPay, createOrg, feed } from "../sim.js";
import OrgCols from "./OrgCols.vue";
import BuildSide from "./BuildSide.vue";

const orgOpen = ref(false);   // 建组织面板平时折叠——组织类型众多，分类承载
/* 地形条：各采集场的场地堆存（缓冲堆，待运输队搬运） */
const terrainRows = computed(() => Object.entries(TERRAIN).map(([site, t]) => {
  const parts = t.products.map(p => ({ p, v: S.buf[site + "|" + p] || 0 }));
  const fill = Math.max(...parts.map(x => x.v / S.knobs.buf));
  return { site, parts, fill };
}));
const staffed = computed(() => S.people.length - idle().length);
/* 耕战一体：动员官（市政厅军事槽有人）才能动员；战备=全体产率减半 */
const milStaffed = computed(() => S.orgs.o01 && S.orgs.o01.slots["军事"].persons.length > 0);
const militia = computed(() => S.mobilized ? S.people.filter(p => p.name.startsWith("村民")).length : 0);
function toggleMob() {
  if (S.mobilized) { S.mobilized = false; feed("解除动员，回到生产", "good"); }
  else { S.mobilized = true; feed("动员令下：转入战备，产率减半", "warn"); }
}
function orgTitle(name) {
  const cost = LATE_COST[name];
  return orgDesc(name) + (cost ? `｜${costStr(cost.res)}` : "") +
         (cost?.prereq ? `｜明面前提：${cost.prereq}` : "");
}
/* 建不了的原因（事件流已撤，拒止反馈落在按钮态上）：前提→资源，与 createOrg 同序 */
function createBlocked(name) {
  const cost = LATE_COST[name];
  if (!cost) return "";
  if (cost.prereq) return "明面前提未满足：" + cost.prereq;
  if (!canPay(cost.res)) return "资源不足：" + costStr(cost.res);
  return "";
}
</script>

<template>
  <div id="orgpage">
    <div id="otool">
      <div class="tgroup">
        <div v-for="t in terrainRows" :key="t.site" class="tchip" :class="{ full: t.fill >= 1 }"
             :title="`场地缓冲堆上限 ${S.knobs.buf}（满则采集停摆，等运输队搬走）`">
          <span class="nm">{{ t.site }}</span>
          <span class="piles">
            <span v-for="x in t.parts" :key="x.p" class="pile">{{ x.p }} {{ x.v.toFixed(0) }}</span>
          </span>
          <div class="bar tb"><i :class="{ mid: t.fill >= .8, full: t.fill >= 1 }"
               :style="{ width: Math.min(100, t.fill * 100) + '%' }"></i></div>
        </div>
      </div>
      <div class="oright">
        <span class="popu" title="在编=挂在各组织槽上；待业=可派">在编 {{ staffed }} · 待业 {{ idle().length }}</span>
        <button class="mob" :class="{ war: S.mobilized }" :disabled="!milStaffed"
                :title="milStaffed ? '耕战一体：平时生产、战时皆兵（战备产率减半）' : '需动员官在市政厅军事槽'"
                @click="toggleMob">
          {{ S.mobilized ? `战备中·民兵${militia}，解除` : "动员" }}
        </button>
        <button class="pri" :class="{ on: orgOpen }" @click="orgOpen = !orgOpen">
          {{ orgOpen ? "收起建组织" : "＋建组织" }}
        </button>
      </div>
    </div>
    <div v-if="orgOpen" id="ocreate">
      <div class="catrow" v-for="c in ORG_CATS" :key="c.cat">
        <span class="cat">{{ c.cat }}</span>
        <button v-for="name in c.names" :key="name" class="obtn"
                :class="{ late: ORGS[name].late }" :disabled="!!createBlocked(name)"
                :title="orgTitle(name) + (createBlocked(name) ? '｜' + createBlocked(name) : '')"
                @click="createOrg(name)">＋{{ name }}<i v-if="ORGS[name].late">后期</i></button>
      </div>
    </div>
    <div id="obody">
      <OrgCols />
      <BuildSide />
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
.oright { display: flex; align-items: center; gap: 8px; margin-left: auto; }
.popu { color: var(--dim); font-size: 11.5px; white-space: nowrap; }
.mob.war { background: #5c441f; border-color: var(--warn); color: var(--warn); }
#ocreate { border-bottom: 1px solid var(--line); background: var(--panel);
           padding: 8px 14px; flex: none; }
.catrow { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; padding: 2px 0; }
.cat { width: 34px; color: var(--dim); font-size: 11.5px; flex: none; }
.obtn { font-size: 11.5px; padding: 3px 9px; }
.obtn.late { color: var(--dim); }
.obtn.late i { font-style: normal; font-size: 10px; color: var(--warn); margin-left: 3px; }
#obody { flex: 1; display: flex; min-height: 0; }
</style>
