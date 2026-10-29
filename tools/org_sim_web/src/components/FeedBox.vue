<script setup>
import { S } from "../sim.js";
</script>

<template>
  <div id="feed">
    <div v-for="(e, i) in S.feed.slice(-40)" :key="i">
      <span class="t">{{ e.t.toFixed(1) }}</span><span :class="e.cls">{{ e.text }}</span>
    </div>
  </div>
</template>

<style scoped>
#feed { height: 110px; flex: none; background: #0d1016; border-top: 1px solid var(--line);
        overflow-y: auto; padding: 5px 12px; font-size: 12px; }
#feed div { padding: 1px 0; color: var(--dim); }
#feed .t { color: #565f72; margin-right: 8px; font-variant-numeric: tabular-nums; }
#feed .good { color: var(--ok); } #feed .bad { color: var(--bad); } #feed .nest { color: var(--nest); }
</style>
