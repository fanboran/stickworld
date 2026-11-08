<script setup>
import { onMounted, onUnmounted, ref, watch } from "vue";
import { S, advance, loadDemo, reset, saveState } from "./sim.js";
import TopBar from "./components/TopBar.vue";
import OrgPage from "./components/OrgPage.vue";
import CityPage from "./components/CityPage.vue";
import Warehouse from "./components/Warehouse.vue";
import Overview from "./components/Overview.vue";

const page = ref(localStorage.getItem("orgsim.tab") || "org");   // org=组织 / city=建筑 / wh=仓库 / ov=总览（页签记忆）
watch(page, p => localStorage.setItem("orgsim.tab", p));
const showKnobs = ref(false);
const seedIn = ref("");   // 按种子重开：留档 seed 可复现初始布局

let timer = null, saveTimer = null;
onMounted(() => {
  timer = setInterval(() => {
    if (S.speed > 0) advance(0.1 * S.speed);   // 时钟在 advance 内自增（与 __sim.advance 直驱同一口径）
  }, 100);
  saveTimer = setInterval(() => { if (S.hours > 0) saveState(); }, 30000);   // 自动存档
  window.addEventListener("beforeunload", saveState);
});
onUnmounted(() => { clearInterval(timer); clearInterval(saveTimer); window.removeEventListener("beforeunload", saveState); });

/* 就地 toast：feed 最新一条浮层 2.6s——操作反馈不再只在总览页可见（审计：静默失败） */
const toast = ref(null);
let toastTimer = null;
watch(() => S.feed.length, () => {
  const f = S.feed[S.feed.length - 1];
  if (!f) return;
  toast.value = f;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.value = null, 2600);
});
function reopenSeed() {
  const n = Number(seedIn.value);
  reset(Number.isFinite(n) && n > 0 ? n : undefined);
  page.value = "org";
}
</script>

<template>
  <div id="shell">
    <TopBar :page="page" @go="p => page = p" @knobs="showKnobs = !showKnobs" />
    <div v-if="showKnobs" id="knobs">
      <span class="knob" v-for="(v, key) in S.knobs" :key="key">
        {{ {gather:'采集/人时',deptGather:'兜底采集/人时',haul:'搬运/人时',craft:'工序/人时',uninfo:'未通报折扣',buf:'场地堆上限',cap:'仓库容量'}[key] }}
        <input type="number" step="0.05" v-model.number="S.knobs[key]">
      </span>
      <span class="knob">本局 seed {{ S.seed }}
        <input type="number" v-model.number="seedIn" placeholder="留档 seed">
        <button @click="reopenSeed">按 seed 重开</button>
      </span>
      <button @click="loadDemo()">载入完全体样板</button>
    </div>
    <OrgPage v-if="page === 'org'" />
    <CityPage v-else-if="page === 'city'" />
    <Warehouse v-else-if="page === 'wh'" />
    <Overview v-else-if="page === 'ov'" />
    <transition name="tst">
      <div v-if="toast" id="toast" :class="toast.cls">{{ toast.text }}</div>
    </transition>
  </div>
</template>

<style scoped>
#shell { display: flex; flex-direction: column; height: 100vh; }
#knobs { display: flex; gap: 8px; flex-wrap: wrap; padding: 6px 14px;
         border-bottom: 1px solid var(--line); background: var(--panel); align-items: center; }
.knob { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; color: var(--dim); }
.knob input { width: 54px; }
#toast { position: fixed; right: 16px; bottom: 16px; max-width: 380px; z-index: 99;
         background: var(--panel3); border: 1px solid var(--line2); border-left: 3px solid var(--acc);
         border-radius: 8px; padding: 7px 12px; font-size: 12px; box-shadow: 0 4px 16px #0008; }
#toast.good { border-left-color: var(--ok); }
#toast.bad { border-left-color: var(--bad); }
#toast.warn { border-left-color: var(--warn); }
.tst-enter-active, .tst-leave-active { transition: opacity .18s, transform .18s; }
.tst-enter-from, .tst-leave-to { opacity: 0; transform: translateY(6px); }
</style>
