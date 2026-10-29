<script setup>
import { computed } from "vue";
import { S, TERRAIN, BUILDINGS } from "../sim.js";
const terrainRows = computed(() => Object.entries(TERRAIN).map(([site, t]) => ({
  site, parts: t.products.map(p => `${p} ${(S.buf[site + "|" + p] || 0).toFixed(0)}`).join(" · "),
  fill: Math.max(...t.products.map(p => (S.buf[site + "|" + p] || 0) / S.knobs.buf)),
})));
const buildRows = computed(() => Object.entries(BUILDINGS).map(([b, d]) => {
  const st = S.buildings[b];
  const eq = d.interior ? d.interior.filter(it => st.interior[it.item]).map(it => it.item) : [];
  return { b, built: st.shell, eq };
}));
</script>

<template>
  <div class="strip">
    <div v-for="t in terrainRows" :key="t.site" class="mini" :class="{ full: t.fill >= 1 }">
      <span class="nm">地形·{{ t.site }}</span> 堆存 {{ t.parts }}
      <div class="bar"><i :style="{ width: Math.min(100, t.fill * 100) + '%' }"></i></div>
    </div>
  </div>
  <div class="strip">
    <div v-for="b in buildRows" :key="b.b" class="mini">
      <template v-if="b.built">
        <span class="nm">{{ b.b }} ✓</span>
        <div class="eq">{{ b.eq.length ? "设备：" + b.eq.join("、") : "无设备（软装空）" }}</div>
      </template>
      <template v-else><span class="nm">{{ b.b }}</span> <span class="bad">未建</span></template>
    </div>
  </div>
</template>
