<script setup>
import { onMounted, onUnmounted, ref } from "vue";
import { S, advance } from "./sim.js";
import TopBar from "./components/TopBar.vue";
import OrgPage from "./components/OrgPage.vue";
import Warehouse from "./components/Warehouse.vue";

const page = ref("org");          // org=组织 / wh=仓库（头部页签切换；建造在组织页右侧栏）
const showKnobs = ref(false);
let timer = null;
onMounted(() => {
  timer = setInterval(() => {
    if (S.speed > 0) {
      const dt = 0.1 * S.speed;
      advance(dt);
      S.hours += dt;
    }
  }, 100);
});
onUnmounted(() => clearInterval(timer));
</script>

<template>
  <div id="shell">
    <TopBar :page="page" @go="p => page = p" @knobs="showKnobs = !showKnobs" />
    <div v-if="showKnobs" id="knobs">
      <span class="knob" v-for="(v, key) in S.knobs" :key="key">
        {{ {gather:'采集/人时',deptGather:'兜底采集/人时',haul:'搬运/人时',craft:'工序/人时',uninfo:'未通报折扣',buf:'场地堆上限',cap:'仓库容量'}[key] }}
        <input type="number" step="0.05" v-model.number="S.knobs[key]">
      </span>
    </div>
    <OrgPage v-if="page === 'org'" />
    <Warehouse v-else-if="page === 'wh'" />
  </div>
</template>

<style scoped>
#shell { display: flex; flex-direction: column; height: 100vh; }
#knobs { display: flex; gap: 8px; flex-wrap: wrap; padding: 6px 14px;
         border-bottom: 1px solid var(--line); background: var(--panel); }
.knob { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; color: var(--dim); }
.knob input { width: 54px; }
</style>
