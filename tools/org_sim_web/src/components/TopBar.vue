<script setup>
import { computed } from "vue";
import { S, BASIC_RES, RES_INFO, resTotal, capTotal, reset, clearSave, housingCap, tabUnlocked } from "../sim.js";
const props = defineProps({ page: String });
const emit = defineEmits(["go", "knobs"]);
const tabs = [
  { id: "org", label: "组织" },
  { id: "city", label: "建筑" },
  { id: "wh", label: "仓库" },
  { id: "ov", label: "总览" },
];
const speeds = [[0, "⏸"], [1, "1×"], [10, "10×"], [100, "100×"]];
const LOCK_HINT = {
  city: "需「生产」槽在编（放人或放生产局——建造线归生产辖）",
  wh: "需「运输」槽在编（放人或放运输队）",
  ov: "需「情报」槽起码有一人（总览＝把各处文书运回的汇总，得有人捎）",
};
const day = computed(() => Math.floor(S.hours / 24) + 1);
const stateText = computed(() =>
  (S.speed === 0 ? "暂停" : S.speed + "×") + (S.mobilized ? " · 战备" : ""));
function doReset() { clearSave(); reset(); emit("go", "org"); }   // 重开=清档新局（普通刷新走存档恢复）
</script>

<template>
  <!-- 标题栏：品牌 + 基础资源 + 时钟倍速/参数/重开 -->
  <div id="top">
    <div class="brand">组织模拟台</div>
    <!-- 顶栏只放基础原料（原木/铁矿/农作物）；材料/制品全在仓库页，来源说明取 RES_INFO 单一真相源 -->
    <span class="res" v-for="r in BASIC_RES" :key="r"
          :title="RES_INFO[r].src + '｜库存 ' + Math.floor(S.res[r]) + '，每时净产 ' + (S.rates[r] > 0 ? '+' : '') + (S.rates[r] || 0).toFixed(1) + '（产量−消耗）'">
      {{ r }}<b>{{ Math.floor(S.res[r]) }}</b>
      <span class="rate" v-if="Math.abs(S.rates[r] || 0) >= 0.005">
        净{{ (S.rates[r] > 0 ? "+" : "") + S.rates[r].toFixed(1) }}/时</span>
    </span>
    <span class="res link" title="人口与居住位（点开组织页看在编/待业；民居每座基准4位，装床铺翻倍）" @click="emit('go', 'org')">
      人口<b>{{ S.people.length }}</b><span class="rate">/居{{ housingCap() }}</span>
    </span>
    <span class="res link" title="点开仓库页" @click="emit('go', 'wh')">
      仓库<b :class="{ lack: resTotal() >= capTotal(), warn90: resTotal() >= capTotal() * 0.9 && resTotal() < capTotal() }">{{ Math.floor(resTotal()) }}</b>
      <span class="rate">/{{ capTotal() }}</span>
    </span>
    <div id="tright">
      <div id="speeds">
        <button v-for="[v, label] in speeds" :key="v" :class="{ on: S.speed === v }"
                class="spd" @click="S.speed = v" :title="v === 0 ? '暂停' : v + ' 倍速'">{{ label }}</button>
      </div>
      <span class="clock">{{ S.hours.toFixed(1) }}时 · 第{{ day }}天（{{ stateText }}）</span>
      <button class="spd" @click="emit('knobs')">参数</button>
      <button class="spd warn" @click="doReset()">重开</button>
    </div>
  </div>
  <!-- 横排：页签独占一排（后续还有更多东西要放这排） -->
  <div id="tabrow">
    <nav id="tabs">
      <!-- 页签解锁（裁决43）：后三页要对应槽位在编——信息有主人；锁页签示因 -->
      <button v-for="t in tabs" :key="t.id" :class="{ on: page === t.id, lock: !tabUnlocked(t.id) }"
              :disabled="!tabUnlocked(t.id)"
              :title="tabUnlocked(t.id) ? '' : LOCK_HINT[t.id]"
              @click="emit('go', t.id)">{{ tabUnlocked(t.id) ? t.label : "🔒 " + t.label }}</button>
    </nav>
  </div>
</template>

<style scoped>
#top { display: flex; align-items: center; gap: 8px; padding: 0 14px; height: 44px;
       background: var(--panel); border-bottom: 1px solid var(--line); flex-wrap: nowrap;
       overflow-x: auto; flex: none; }
.brand { font-weight: 700; font-size: 14px; margin-right: 6px; white-space: nowrap; }
.res { display: inline-flex; align-items: center; gap: 5px; background: var(--panel2);
       border: 1px solid var(--line); border-radius: 8px; padding: 3px 10px; font-size: 12px;
       white-space: nowrap; }
.res b { font-variant-numeric: tabular-nums; }
.res .rate { color: var(--dim); font-size: 11px; font-variant-numeric: tabular-nums; }
.res.link { cursor: pointer; }
.res.link:hover { border-color: var(--acc); }
.res b.lack { color: var(--bad); }
.res b.warn90 { color: var(--warn); }   /* 近满中间档（≥90%）：满为红、近满为琥珀 */
#tright { margin-left: auto; display: flex; align-items: center; gap: 5px; white-space: nowrap; }
#tright .spd { padding: 3px 8px; font-size: 11.5px; }
/* 速度＝分段控件（一组里的互斥选择），与参数/重开等单发按钮区隔 */
#speeds { display: flex; background: var(--panel2); border: 1px solid var(--line);
          border-radius: 8px; overflow: hidden; }
#speeds .spd { border: 0; border-radius: 0; border-right: 1px solid var(--line);
               background: transparent; padding: 3px 9px; }
#speeds .spd:last-child { border-right: 0; }
#speeds .spd.on { background: #2f8a5c; color: #fff; font-weight: 600; }
.clock { color: var(--dim); font-size: 12px; margin: 0 4px; font-variant-numeric: tabular-nums; }

#tabrow { display: flex; background: var(--panel); border-bottom: 1px solid var(--line);
          flex: none; }
/* 页签独占一排即平分整排（后续新增的横排项同样平分） */
#tabs { display: flex; flex: 1; min-width: 0; }
#tabs button { flex: 1; border: 0; border-right: 1px solid var(--line); border-radius: 0;
               background: transparent; color: var(--dim); padding: 6px 0;
               font-size: 12.5px; box-shadow: inset 0 0 0 0 transparent; }
#tabs button:last-child { border-right: 0; }
#tabs button:hover:not(.on) { color: var(--fg); background: #ffffff07; }
#tabs button.on { background: #2c4d8f; color: #fff; }
#tabs button.lock { color: var(--faint); }
</style>
