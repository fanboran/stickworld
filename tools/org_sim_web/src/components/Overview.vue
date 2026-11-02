<script setup>
import { computed } from "vue";
import { S, RES, RES_INFO, RES_CATS, TERRAIN, resTotal, capTotal,
         intelLevel, idle, buildWorkers, membersOf } from "../sim.js";

/* 一站式信息总览：可视深度随情报组织规模而长——
   lv1(情报槽有人)=基础总览 · lv2(情报局·汇总在编)=+三线运转 · lv3(抄送在编)=+呈报流 */
const lv = computed(() => intelLevel());
const day = computed(() => Math.floor(S.hours / 24) + 1);
const resRows = computed(() => RES.filter(r => S.res[r] > 0.05 || Math.abs(S.rates[r] || 0) >= 0.005)
  .map(r => ({ r, icon: RES_INFO[r].icon, cat: RES_INFO[r].cat, v: S.res[r], rate: S.rates[r] || 0 })));
const siteRows = computed(() => Object.entries(TERRAIN).flatMap(([site, t]) =>
  t.products.map(p => ({ site, p, v: S.buf[site + "|" + p] || 0 }))));
const byTpl = n => Object.values(S.orgs).find(o => o.template === n);
const lineCard = computed(() => {
  if (lv.value < 2) return null;
  const g = t => { const o = byTpl(t); return o ? membersOf(o) : 0; };
  return [
    { name: "采集线", rows: [["伐木队", g("伐木队")], ["采矿队", g("采矿队")], ["农垦队", g("农垦队")]] },
    { name: "运输线", rows: [["运输队", g("运输队")], ["库务所", g("库务所")], ["调度在岗", byTpl("运输队")?.slots["调度"].persons.length || 0]] },
    { name: "制造线", rows: [["锯木坊", g("锯木坊")], ["锻造坊", g("锻造坊")], ["药剂坊", g("药剂坊")], ["木器坊", g("木器坊")], ["冶炼坊", g("冶炼坊")]] },
    { name: "军政", rows: [["常备军", g("常备军")], ["训练营", g("训练营")], ["科研院", g("科研院")], ["情报局", g("情报局")]] },
  ];
});
const queue = computed(() => S.buildOrders.map(o => ({
  label: o.kind === "shell" ? o.b + "·新座" : o.b + "·" + o.item,
  pct: Math.round(100 * o.done / o.work) })));
const feedRows = computed(() => S.feed.slice(-30).reverse());
</script>

<template>
  <div id="ov">
    <template v-if="lv === 0">
      <div class="nolvl">没有人在汇总情报——一站式总览不可用。派人到市政厅「情报」槽，或构筑情报局。</div>
    </template>
    <template v-else>
      <!-- lv1 基础总览 -->
      <section class="osec">
        <h3>城市</h3>
        <div class="crow">
          <span class="kpi">第{{ day }}天 · {{ S.hours.toFixed(1) }}时</span>
          <span class="kpi" :class="{ war: S.mobilized }">{{ S.mobilized ? "战备中·产率减半" : "平时" }}</span>
          <span class="kpi">在编 {{ S.people.length - idle().length }} · 待业 {{ idle().length }}</span>
          <span class="kpi">施工 {{ buildWorkers() }} 人</span>
          <span class="kpi">仓库 {{ Math.floor(resTotal()) }}/{{ capTotal() }}</span>
        </div>
      </section>
      <section class="osec">
        <h3>资产</h3>
        <div class="rrow" v-for="row in resRows" :key="row.r">
          <span class="ric">{{ row.icon }}</span>
          <span class="rname">{{ row.r }}</span>
          <span class="rcat">{{ RES_CATS.find(c => c[0] === row.cat)?.[1] }}</span>
          <b class="rv">{{ row.v.toFixed(1) }}</b>
          <span class="rr" :class="{ up: row.rate > 0, down: row.rate < 0 }">
            {{ row.rate >= 0 ? "+" : "" }}{{ row.rate.toFixed(1) }}/时</span>
        </div>
      </section>
      <section class="osec">
        <h3>施工</h3>
        <div v-if="queue.length" class="qrow" v-for="q in queue" :key="q.label">
          <span>{{ q.label }}</span>
          <div class="bar"><i :style="{ width: q.pct + '%' }"></i></div>
          <span class="dim">{{ q.pct }}%</span>
        </div>
        <div v-else class="dim">队列为空</div>
      </section>

      <!-- lv2 三线运转 -->
      <template v-if="lv >= 2">
        <section class="osec">
          <h3>场地堆存</h3>
          <div class="srow2" v-for="t in siteRows" :key="t.site + t.p">
            <span>{{ t.site }}·{{ t.p }}</span>
            <div class="bar"><i :class="{ mid: t.v / S.knobs.buf >= .8, full: t.v >= S.knobs.buf }"
                 :style="{ width: Math.min(100, t.v / S.knobs.buf * 100) + '%' }"></i></div>
            <span class="dim">{{ t.v.toFixed(0) }}/{{ S.knobs.buf }}</span>
          </div>
        </section>
        <section class="osec" v-for="card in lineCard" :key="card.name">
          <h3>{{ card.name }}</h3>
          <div class="crow">
            <span class="kpi" v-for="[n, v] in card.rows" :key="n">{{ n }} <b>{{ v }}</b></span>
          </div>
        </section>
      </template>

      <!-- lv3 呈报流 -->
      <section class="osec" v-if="lv >= 3">
        <h3>呈报流（各信息岗呈递）</h3>
        <div class="feedlist">
          <div v-for="(f, i) in feedRows" :key="i">
            <span class="t">{{ f.t.toFixed(1) }}</span><span :class="f.cls">{{ f.text }}</span>
          </div>
        </div>
      </section>
      <div class="hint">总览深度由情报组织规模决定：情报槽有人＝基础 · 情报局汇总在编＝三线运转 · 抄送在编＝呈报流</div>
    </template>
  </div>
</template>

<style scoped>
#ov { flex: 1; overflow-y: auto; padding: 12px 16px 20px; }
.nolvl { color: var(--dim); padding: 24px 0; text-align: center; }
.osec { margin-bottom: 14px; }
.osec h3 { font-size: 12px; color: var(--dim); font-weight: 600; margin: 0 0 6px; }
.crow { display: flex; gap: 8px; flex-wrap: wrap; }
.kpi { background: var(--panel2); border: 1px solid var(--line); border-radius: 8px;
       padding: 3px 10px; font-size: 12px; }
.kpi b { font-variant-numeric: tabular-nums; }
.kpi.war { color: var(--warn); border-color: var(--warn); }
.rrow { display: flex; align-items: center; gap: 8px; padding: 2px 0; font-size: 12px;
        border-bottom: 1px dashed var(--line); }
.rrow .ric { width: 18px; text-align: center; }
.rrow .rname { width: 52px; }
.rrow .rcat { color: var(--faint); font-size: 10.5px; width: 52px; }
.rrow .rv { margin-left: auto; font-variant-numeric: tabular-nums; }
.rrow .rr { width: 72px; text-align: right; font-variant-numeric: tabular-nums; font-size: 11px; }
.rr.up { color: var(--ok); } .rr.down { color: var(--bad); }
.qrow, .srow2 { display: flex; align-items: center; gap: 8px; padding: 2px 0; font-size: 12px; }
.qrow .bar, .srow2 .bar { flex: 1; max-width: 220px; }
.dim { color: var(--dim); font-size: 11px; font-variant-numeric: tabular-nums; }
.feedlist { font-size: 11.5px; max-height: 220px; overflow-y: auto; background: var(--panel2);
            border: 1px solid var(--line); border-radius: 8px; padding: 6px 10px; }
.feedlist div { padding: 1px 0; }
.feedlist .t { color: #565f72; margin-right: 8px; font-variant-numeric: tabular-nums; }
.hint { color: var(--faint); font-size: 10.5px; margin-top: 8px; }
</style>
