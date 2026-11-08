<script setup>
import { computed, ref } from "vue";
import { S, RES, RES_INFO, RES_CATS, TERRAIN, intelInterval } from "../sim.js";

/* 一站式总览＝运回市政厅的文书快照：信息量不随情报规模 gate（各组织面板自有数据源），
   情报组织规模只决定更新效率；段落的置顶/挂主菜单是玩家自己的设置 */
const snap = computed(() => S.snap);
const iv = computed(() => intelInterval());
const stale = computed(() => snap.value && S.hours - snap.value.at > Math.min(iv.value, 24) + 0.001);
const headText = computed(() => {
  if (!snap.value) return "";
  if (iv.value === Infinity) return "停更——无人把文书运回市政厅";
  return `截至 ${snap.value.at.toFixed(1)} 时 · 更新周期 ${iv.value} 时`;
});

const SECTIONS = ["城市", "资产", "施工", "场地堆存", "三线运转", "呈报流"];
const pins = ref(JSON.parse(localStorage.getItem("ovPins") || '["城市","资产"]'));
function togglePin(name) {
  pins.value = pins.value.includes(name)
    ? pins.value.filter(x => x !== name) : [...pins.value, name];
  localStorage.setItem("ovPins", JSON.stringify(pins.value));
}
const pinned = computed(() => SECTIONS.filter(x => pins.value.includes(x)));
const inMenu = computed(() => SECTIONS.filter(x => !pins.value.includes(x)));

const d = computed(() => snap.value || { at: 0, res: {}, rates: {}, buf: {}, queue: [], lines: {}, feed: [], popu: { total: 0, idle: 0 } });
const resRows = computed(() => RES.filter(r => (d.value.res[r] || 0) > 0.05 || Math.abs(d.value.rates[r] || 0) >= 0.005)
  .map(r => ({ r, icon: RES_INFO[r].icon, cat: RES_INFO[r].cat, v: d.value.res[r] || 0, rate: d.value.rates[r] || 0 })));
const siteRows = computed(() => Object.entries(TERRAIN).flatMap(([site, t]) =>
  t.products.map(p => ({ site, p, v: d.value.buf[site + "|" + p] || 0 }))));
const LINE_GROUPS = [
  { name: "采集", keys: ["伐木队", "采矿队", "农垦队"] },
  { name: "运输", keys: ["运输队", "库务所"] },
  { name: "制造", keys: ["锯木坊", "锻造坊", "药剂坊", "木器坊", "冶炼坊"] },
  { name: "军政", keys: ["常备军", "科研院", "情报局"] },
];
const menuSum = computed(() => ({
  "施工": d.value.queue.length ? `施工中 ${d.value.queue.length} 单` : "队列空",
  "场地堆存": siteRows.value.some(t => t.v >= S.knobs.buf) ? "有堆满" : `${siteRows.value.filter(t => t.v > 0.5).length} 处有存`,
  "三线运转": `${d.value.lines["情报局"] ?? 0} 情报在编`,
  "呈报流": `最近 ${d.value.feed.length} 条`,
}));
</script>

<template>
  <div id="ov">
    <div class="ovhead">
      <span :class="{ stale: stale || iv === Infinity }">{{ headText }}</span>
      <span class="dim">情报规模决定更新效率，不决定信息量——各组织面板自有数据源</span>
    </div>

    <template v-for="name in pinned" :key="name">
      <section class="osec">
        <h3>{{ name }} <button class="pin" @click="togglePin(name)">取消置顶</button></h3>

        <div v-if="name === '城市'" class="crow">
          <span class="kpi">在编 {{ d.popu.total - d.popu.idle }} · 待业 {{ d.popu.idle }}</span>
          <span class="kpi" v-for="(v, k) in d.lines" :key="k" v-show="['运输队','常备军','情报局'].includes(k)">{{ k }} <b>{{ v }}</b></span>
        </div>

        <template v-if="name === '资产'">
          <div class="rhead2"><span>物品</span><span style="margin-left:auto">库存</span><span style="width:72px;text-align:right">每时净产</span></div>
          <div class="rrow" v-for="row in resRows" :key="row.r">
            <span class="ric">{{ row.icon }}</span><span class="rname">{{ row.r }}</span>
            <span class="rcat">{{ RES_CATS.find(c => c[0] === row.cat)?.[1] }}</span>
            <b class="rv">{{ row.v.toFixed(1) }}</b>
            <span class="rr" :class="{ up: row.rate > 0, down: row.rate < 0 }">
              {{ row.rate >= 0 ? "+" : "" }}{{ row.rate.toFixed(1) }}/时</span>
          </div>
        </template>

        <template v-if="name === '施工'">
          <div v-if="d.queue.length" class="qrow" v-for="q in d.queue" :key="q.label">
            <span>{{ q.label }}</span>
            <div class="bar"><i :style="{ width: q.pct + '%' }"></i></div>
            <span class="dim">{{ q.pct }}%</span>
          </div>
          <div v-else class="dim">队列为空</div>
        </template>

        <template v-if="name === '场地堆存'">
          <div class="srow2" v-for="t in siteRows" :key="t.site + t.p">
            <span>{{ t.site }}·{{ t.p }}</span>
            <div class="bar"><i :class="{ mid: t.v / S.knobs.buf >= .8, full: t.v >= S.knobs.buf }"
                 :style="{ width: Math.min(100, t.v / S.knobs.buf * 100) + '%' }"></i></div>
            <span class="dim">{{ t.v.toFixed(0) }}/{{ S.knobs.buf }}</span>
          </div>
        </template>

        <template v-if="name === '三线运转'">
          <div class="lgroup" v-for="g in LINE_GROUPS" :key="g.name">
            <span class="lname">{{ g.name }}</span>
            <span class="kpi" v-for="k in g.keys" :key="k">{{ k }} <b>{{ d.lines[k] ?? 0 }}</b></span>
          </div>
        </template>

        <template v-if="name === '呈报流'">
          <div class="feedlist">
            <div v-for="(f, i) in d.feed" :key="i">
              <span class="t">{{ f.t.toFixed(1) }}</span><span :class="f.cls">{{ f.text }}</span>
            </div>
          </div>
        </template>
      </section>
    </template>

    <!-- 挂在主菜单：玩家收起的段落，一行一条随时可置顶 -->
    <section class="osec menu">
      <h3>主菜单（点段落名置顶）</h3>
      <div class="mrow" v-for="name in inMenu" :key="name" @click="togglePin(name)">
        <span>{{ name }}</span><span class="dim">{{ menuSum[name] }}</span><i class="pin-hint">置顶 ›</i>
      </div>
    </section>
  </div>
</template>

<style scoped>
#ov { flex: 1; overflow-y: auto; padding: 12px 16px 20px; }
.ovhead { display: flex; align-items: baseline; gap: 12px; margin-bottom: 10px;
          color: var(--dim); font-size: 12px; }
.ovhead .stale { color: var(--bad); font-weight: 700; }
.dim { color: var(--dim); font-size: 11px; font-variant-numeric: tabular-nums; }
.osec { margin-bottom: 14px; }
.osec h3 { font-size: 12px; color: var(--dim); font-weight: 600; margin: 0 0 6px;
           display: flex; align-items: center; gap: 8px; }
.pin { font-size: 10px; padding: 1px 7px; color: var(--dim); }
.crow, .lgroup { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 4px; }
.lname { color: var(--faint); font-size: 11px; width: 30px; align-self: center; }
.kpi { background: var(--panel2); border: 1px solid var(--line); border-radius: 8px;
       padding: 3px 10px; font-size: 12px; }
.kpi b { font-variant-numeric: tabular-nums; }
.rhead2 { display: flex; gap: 8px; font-size: 10px; color: var(--faint); padding: 0 0 2px; }
.rrow { display: flex; align-items: center; gap: 8px; padding: 2px 0; font-size: 12px;
        border-bottom: 1px dashed var(--line); }
.rrow .ric { width: 18px; text-align: center; }
.rrow .rname { width: 52px; } .rrow .rcat { color: var(--faint); font-size: 10.5px; width: 52px; }
.rrow .rv { margin-left: auto; font-variant-numeric: tabular-nums; }
.rrow .rr { width: 72px; text-align: right; font-variant-numeric: tabular-nums; font-size: 11px; }
.rr.up { color: var(--ok); } .rr.down { color: var(--bad); }
.qrow, .srow2 { display: flex; align-items: center; gap: 8px; padding: 2px 0; font-size: 12px; }
.qrow .bar, .srow2 .bar { flex: 1; max-width: 220px; }
.feedlist { font-size: 11.5px; max-height: 220px; overflow-y: auto; background: var(--panel2);
            border: 1px solid var(--line); border-radius: 8px; padding: 6px 10px; }
.feedlist .t { color: #565f72; margin-right: 8px; font-variant-numeric: tabular-nums; }
.menu .mrow { display: flex; gap: 10px; padding: 3px 8px; font-size: 12px;
              border-radius: 6px; cursor: pointer; }
.menu .mrow .dim { margin-left: auto; }
.menu .mrow .pin-hint { font-style: normal; color: var(--faint); font-size: 10px; align-self: center;
                       opacity: 0; transition: opacity .12s; }
.menu .mrow:hover { background: #ffffff08; color: var(--acc); }
.menu .mrow:hover .pin-hint { opacity: 1; }   /* hover 才亮出「置顶 ›」——行可点的 affordance */
</style>
