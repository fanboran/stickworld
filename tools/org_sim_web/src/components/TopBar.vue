<script setup>
import { computed } from "vue";
import { S, RES, resTotal, capTotal, reset } from "../sim.js";
const emit = defineEmits(["toggle-knobs"]);
const speeds = [[0, "⏸"], [1, "1×"], [10, "10×"], [100, "100×"]];
const day = computed(() => Math.floor(S.hours / 24) + 1);
const stateText = computed(() =>
  (S.speed === 0 ? "暂停" : S.speed + "×") + (S.mobilized ? " · 战备" : ""));
function setSpeed(v) { S.speed = v; }
</script>

<template>
  <div id="top">
    <h1>组织模拟台</h1>
    <button v-for="[v, label] in speeds" :key="v" :class="{ on: S.speed === v }"
            @click="setSpeed(v)">{{ label }}</button>
    <button class="ghost" @click="emit('toggle-knobs')">参数</button>
    <button class="warn" @click="reset()">重开</button>
    <span class="res" v-for="r in RES" :key="r">
      {{ r }} <b>{{ Math.floor(S.res[r]) }}</b>
      <span class="rate">{{ Math.abs(S.rates[r] || 0) >= 0.005 ? ((S.rates[r] > 0 ? "+" : "") + (S.rates[r] || 0).toFixed(1)) : "0.0" }}/时</span>
    </span>
    <span class="res">仓库 <b>{{ Math.floor(resTotal()) }}</b><span class="rate">/{{ capTotal() }}</span></span>
    <span id="clock">{{ S.hours.toFixed(1) }} 时 · 第 {{ day }} 天（{{ stateText }}）</span>
  </div>
</template>

<style scoped>
#top { display: flex; align-items: center; gap: 10px; padding: 8px 12px;
       background: var(--panel); border-bottom: 1px solid var(--line); flex-wrap: wrap; }
#top h1 { font-size: 14px; margin-right: 4px; }
#clock { margin-left: auto; color: var(--dim); font-variant-numeric: tabular-nums; }
</style>
