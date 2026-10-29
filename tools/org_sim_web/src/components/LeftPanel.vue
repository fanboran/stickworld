<script setup>
import { computed } from "vue";
import { S, ORGS, BUILDINGS, orgDesc, costStr, createOrg, queueBuild } from "../sim.js";
const quickOrgs = computed(() => Object.entries(ORGS).filter(([, t]) => !t.late));
const lateOrgs = ["冶炼坊", "常备军", "训练营", "科研院"];
const buildable = computed(() => Object.entries(BUILDINGS).filter(([, d]) => !d.prebuilt));
const curOrder = computed(() => S.buildOrders[0] || null);
function orderLabel(o) { return o.kind === "shell" ? o.b + "·硬装" : o.b + "·" + o.item; }
</script>

<template>
  <div id="left">
    <h3>建组织</h3>
    <button v-for="[name] in quickOrgs" :key="name" @click="createOrg(name)">
      + {{ name }} <span class="cost">{{ orgDesc(name) }}</span>
    </button>
    <details>
      <summary>后期组织（低存在感）</summary>
      <button v-for="name in lateOrgs" :key="name" @click="createOrg(name)">+ {{ name }}</button>
    </details>
    <h3>建造（硬装=建筑体/窗位，软装=设备/桌椅）</h3>
    <template v-for="[b, d] in buildable" :key="b">
      <div class="bhead"><b>{{ b }}</b> {{ S.buildings[b].shell ? "硬装✓" : "" }}</div>
      <button v-if="!S.buildings[b].shell" class="ghost"
              @click="queueBuild('shell', b)">
        硬装（建筑体/窗位）<span class="cost">{{ costStr(d.shell.cost) }}·{{ d.shell.work }}人时</span>
      </button>
      <template v-else>
        <template v-for="it in d.interior" :key="it.item">
          <div v-if="S.buildings[b].interior[it.item]" class="cost done">
            {{ it.item }} ✓ {{ it.unlock || it.effect || "" }}
          </div>
          <button v-else class="ghost" @click="queueBuild('interior', b, it.item)">
            软装·{{ it.item }}<span class="cost">{{ costStr(it.cost) }}·{{ it.work }}人时</span>
          </button>
        </template>
      </template>
    </template>
    <div class="cost" v-if="curOrder">
      施工中：{{ orderLabel(curOrder) }} {{ (100 * curOrder.done / curOrder.work).toFixed(0) }}%（队列{{ S.buildOrders.length }}）
    </div>
  </div>
</template>

<style scoped>
#left { width: 228px; flex: none; background: var(--panel); border-right: 1px solid var(--line);
        overflow-y: auto; padding: 8px; }
#left h3 { font-size: 12px; color: var(--dim); margin: 10px 0 6px; }
#left button { display: block; width: 100%; text-align: left; margin: 3px 0; padding: 5px 8px; }
#left details { margin-top: 8px; }
#left summary { cursor: pointer; color: var(--dim); font-size: 12px; }
.bhead { font-size: 12px; margin: 5px 0 2px; }
.done { color: var(--flow); }
</style>
