<script setup>
import { onMounted, onUnmounted, ref } from "vue";
import { S, advance, reset } from "./sim.js";
import TopBar from "./components/TopBar.vue";
import Strips from "./components/Strips.vue";
import LeftPanel from "./components/LeftPanel.vue";
import OrgCols from "./components/OrgCols.vue";
import RightPanel from "./components/RightPanel.vue";
import FeedBox from "./components/FeedBox.vue";

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
  <TopBar @toggle-knobs="showKnobs = !showKnobs" />
  <div v-if="showKnobs" id="knobs">
    <span class="knob" v-for="(v, key) in S.knobs" :key="key">
      {{ {gather:'采集/人时',haul:'搬运/人时',craft:'工序/人时',uninfo:'未通报折扣',buf:'场地堆上限',cap:'仓库容量'}[key] }}
      <input type="number" step="0.05" v-model.number="S.knobs[key]">
    </span>
  </div>
  <Strips />
  <div id="main">
    <LeftPanel />
    <div id="center"><OrgCols /></div>
    <RightPanel />
  </div>
  <FeedBox />
</template>

<style scoped>
#knobs { display: flex; gap: 6px; flex-wrap: wrap; padding: 6px 12px;
         border-bottom: 1px solid var(--line); background: var(--panel); }
.knob { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; color: var(--dim); }
.knob input { width: 52px; }
#main { display: flex; flex: 1; min-height: 0; }
#center { flex: 1; display: flex; flex-direction: column; min-width: 0; }
</style>
