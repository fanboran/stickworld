<script setup>
import { computed, ref } from "vue";
import { S, RES, RES_INFO, RES_CATS, TERRAIN, resTotal, capTotal, catTotal, capOfCat,
         wipList, mineBufCap, satWarehouses } from "../sim.js";
const tab = ref("all");
const tabs = [
  { id: "all", label: "全部" },
  ...RES_CATS.map(([id, label]) => ({ id, label })),
  { id: "site", label: "场地堆存" },
  { id: "wip", label: "厂内半成品" },
];
const capRatio = computed(() => Math.min(1, resTotal() / capTotal()));
const shownGroups = computed(() => {
  const all = RES_CATS.map(([cat, label]) => ({
    label, items: RES.filter(r => RES_INFO[r].cat === cat),
  }));
  if (tab.value === "all") return all;
  return all.filter(g => g.label === tab.value);
});
const siteRows = computed(() => Object.entries(TERRAIN)
  .flatMap(([site, t]) => t.products.map(p => ({ site, p, v: S.buf[site + "|" + p] || 0, sat: !!t.satellite }))));
const mineCap = computed(() => mineBufCap());
const wipRows = computed(() => wipList());
const INTAKE_RES = ["原木", "铁矿", "农作物"];
function barCls(r) { return r >= 1 ? "full" : r >= .8 ? "mid" : ""; }
</script>

<template>
  <div id="wh">
    <div id="whtabs">
      <button v-for="t in tabs" :key="t.id" :class="{ on: tab === t.id }"
              @click="tab = t.id">{{ t.label }}</button>
      <div class="capbox" title="全城库存总占位 / 分类容量合计">
        <span class="caplbl">{{ Math.floor(resTotal()) }} / {{ capTotal() }}</span>
        <div class="bar cap"><i :class="barCls(capRatio)" :style="{ width: capRatio * 100 + '%' }"></i></div>
      </div>
    </div>
    <!-- 收货政策（拉动制物流，裁决34）：默认全关——产出先堆产地空地，开哪条线搬运工才回运哪条 -->
    <div id="intake">
      <span class="ilbl" title="产出默认堆在产地空地（树林/耕地无上限、矿洞有堆容）；开收的线才回运入库">收货政策</span>
      <button v-for="r in INTAKE_RES" :key="r" class="ibtn" :class="{ on: S.intake[r] }"
              @click="S.intake[r] = !S.intake[r]">{{ RES_INFO[r].icon }}{{ r }}{{ S.intake[r] ? "·收" : "·停" }}</button>
      <span class="catcap" v-for="[c, lab] of RES_CATS" :key="c"
            :title="lab + '类容量＝收该类的仓库座数×600（各类独立，满一类不堵别的）——建筑页可逐座设收货类型'">
        {{ lab }} {{ Math.floor(catTotal(c)) }}/{{ capOfCat(c) }}</span>
    </div>
    <div id="whbody">
      <template v-if="tab === 'site'">
        <div class="lbl">三线场地堆＝产地空地（默认就在这堆着，收货政策开了才回运）：矿洞＝卫星城
    （堆容 {{ mineCap }}，满则停采——卫星仓 +80/座，现 {{ satWarehouses() }} 座）；树林/耕地＝主城侧（堆不设上限）</div>
        <div class="sitegrid">
          <div v-for="r in siteRows" :key="r.site + r.p" class="sitecard"
               :class="{ full: r.sat && r.v >= mineCap }">
            <div class="nm">{{ r.site }}{{ r.sat ? "·卫星" : "·城内" }} · {{ r.p }}{{ S.intake[r.p] ? "（待运）" : "（停收·堆场）" }}</div>
            <div class="qty">{{ r.v.toFixed(1) }} <span class="dim">{{ r.sat ? "/ 矿堆容 " + mineCap : "（无上限）" }}</span></div>
            <div class="bar" v-if="r.sat"><i :class="barCls(r.v / mineCap)"
                 :style="{ width: Math.min(100, r.v / mineCap * 100) + '%' }"></i></div>
          </div>
        </div>
      </template>
      <template v-else-if="tab === 'wip'">
        <div class="lbl">厂内半成品不出厂（铁水/毛坯/淬火件/净药材/车料），随工序在厂内流转</div>
        <div v-if="!wipRows.length" class="empty">厂内暂无半成品——向制造组织派工后在此可见</div>
        <div v-for="r in wipRows" :key="r.org + r.item" class="wiprow">
          <span class="org">{{ r.org }}</span><span class="item">▸ {{ r.item }}</span>
          <b>{{ r.qty.toFixed(1) }}</b>
        </div>
      </template>
      <template v-else>
        <section v-for="g in shownGroups" :key="g.label">
          <div class="ghead">{{ g.label }}</div>
          <div class="tilegrid">
            <div v-for="r in g.items" :key="r" class="tile" :class="{ zero: !S.res[r] }"
                 :title="RES_INFO[r].src">
              <div class="tico">{{ RES_INFO[r].icon }}</div>
              <div class="tnm">{{ r }}</div>
              <div class="tqty"><span class="tunit">库存</span>{{ Math.floor(S.res[r]) }}</div>
              <div class="trate" v-if="Math.abs(S.rates[r] || 0) >= 0.005">
                净{{ (S.rates[r] > 0 ? "+" : "") + S.rates[r].toFixed(1) }}/时</div>
              <div class="trate" v-else>&nbsp;</div>
            </div>
          </div>
        </section>
      </template>
    </div>
  </div>
</template>

<style scoped>
#wh { flex: 1; display: flex; flex-direction: column; min-height: 0; }
#whtabs { display: flex; align-items: flex-end; gap: 5px; padding: 8px 16px 0;
          border-bottom: 1px solid var(--line); background: var(--panel); }
#whtabs button { border-radius: 7px 7px 0 0; border-bottom-color: transparent; padding: 4px 14px; }
#whtabs button.on { background: var(--panel3); border-color: var(--line2); border-bottom: 2px solid var(--acc); }
.capbox { margin-left: auto; display: flex; align-items: center; gap: 8px; padding-bottom: 6px; }
.caplbl { font-size: 12px; color: var(--dim); font-variant-numeric: tabular-nums; }
.capbox .bar { width: 130px; }
#intake { display: flex; align-items: center; gap: 8px; padding: 6px 16px; border-bottom: 1px solid var(--line);
          background: #131826; flex-wrap: wrap; }
#intake .ilbl { color: var(--dim); font-size: 11px; font-weight: 600; }
#intake .ibtn { font-size: 11px; padding: 2px 9px; }
#intake .catcap { color: var(--faint); font-size: 10.5px; margin-left: 8px; font-variant-numeric: tabular-nums; }
#whbody { flex: 1; overflow-y: auto; padding: 12px 16px 20px; }
.ghead { color: var(--dim); font-size: 12px; font-weight: 600; margin: 8px 0 6px; }
.tilegrid { display: flex; gap: 8px; flex-wrap: wrap; }
.tile { width: 96px; background: var(--panel2); border: 1px solid var(--line); border-radius: 10px;
        padding: 9px 6px 7px; text-align: center; }
.tile.zero { opacity: .35; }
.tile .tico { font-size: 24px; line-height: 1.2; }
.tile .tnm { font-size: 12px; color: var(--dim); margin-top: 2px; }
.tile .tqty { font-size: 15px; font-weight: 700; font-variant-numeric: tabular-nums; }
.tile .tunit { font-size: 9px; color: var(--faint); font-weight: 400; margin-right: 3px; }
.tile .trate { font-size: 10.5px; color: var(--dim); font-variant-numeric: tabular-nums; }
.sitegrid { display: flex; gap: 8px; flex-wrap: wrap; }
.sitecard { width: 190px; background: var(--panel2); border: 1px solid var(--line);
            border-radius: 9px; padding: 8px 10px; }
.sitecard.full { border-color: var(--bad); }
.sitecard .nm { color: var(--dim); font-size: 12px; }
.sitecard .qty { font-size: 15px; font-weight: 700; margin: 2px 0 4px; font-variant-numeric: tabular-nums; }
.sitecard .dim { color: var(--faint); font-size: 11px; font-weight: 400; }
.wiprow { display: flex; gap: 8px; align-items: center; background: var(--panel2);
          border: 1px solid var(--line); border-radius: 8px; padding: 5px 12px; width: 320px;
          margin: 4px 0; }
.wiprow .org { color: var(--flow); }
.wiprow .item { color: var(--dim); }
.wiprow b { margin-left: auto; font-variant-numeric: tabular-nums; }
.empty { color: var(--faint); padding: 10px 0; }
.lbl { margin-top: 0; }
</style>
