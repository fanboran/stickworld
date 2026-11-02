<script setup>
import { computed, ref } from "vue";
import { S, BUILDINGS, RES_INFO, CIRC, canPay, queueBuild, buildWorkers } from "../sim.js";

/* 建造侧栏：建筑按座计（同型可多座、每座独立软装）。类型行点开＝再建一座 + 分座设备安装 */
const openB = ref("");
const cur = computed(() => S.buildOrders[0] || null);
const pending = computed(() => S.buildOrders.slice(1));
const workers = computed(() => buildWorkers());
const orderLabel = o => o.kind === "shell"
  ? o.b + "·新座硬装"
  : o.b + CIRC[o.idx] + "·" + o.item;
function toggle(b) { openB.value = openB === b ? "" : b; }
function instQueued(b, item, idx) {
  return S.buildOrders.some(o => o.b === b && o.item === item && o.idx === idx);
}
const lack = (r, n) => S.res[r] < n;
</script>

<template>
  <div id="buildside">
    <div class="bshead">
      建造
      <span class="sub" title="施工人力＝工程队「施工」槽在岗人数；一单一个工地，可多单并进">人力 {{ workers }}</span>
    </div>
    <div class="bq" v-if="cur" title="硬装＝建筑体/窗位 · 软装＝设备/桌椅；组织无建筑可基础运转，建筑解锁进阶">
      <b>{{ orderLabel(cur) }}</b>
      <div class="bar"><i :style="{ width: (100 * cur.done / cur.work) + '%' }"></i></div>
      <span class="qpct">{{ (100 * cur.done / cur.work).toFixed(0) }}%</span>
      <span class="qp" v-if="pending.length">+{{ pending.length }}排队</span>
      <span class="qwarn" v-if="!workers">无人施工</span>
    </div>
    <div class="bslist">
      <template v-for="[b, d] in Object.entries(BUILDINGS)" :key="b">
        <div v-if="d.prebuilt" class="brow pre" :title="d.desc">
          <span class="bname">{{ b }}</span><span class="dim">自带</span>
        </div>
        <div v-else class="bwrap">
          <div class="brow" :class="{ open: openB === b }" @click="toggle(b)">
            <span class="bname">{{ b }}</span>
          </div>
          <div v-if="openB === b" class="bexp" @click.stop>
            <div class="bdesc">{{ d.desc }}</div>
            <button class="pri newb" :disabled="!canPay(d.shell.cost)"
                    :title="canPay(d.shell.cost) ? d.shell.work + '人时' : '资源不足'"
                    @click="queueBuild('shell', b)">
              再建一座·{{ d.shell.work }}人时
              <span class="cost" v-for="[r, n] of Object.entries(d.shell.cost)" :key="r"
                    :class="{ lack: lack(r, n) }">{{ RES_INFO[r].icon }}{{ n }}</span>
            </button>
            <div v-for="(inst, idx) in S.buildings[b]" :key="idx" class="inst">
              <div class="ihead">
                <b>{{ CIRC[idx] }}</b>
                <span class="fx" v-if="inst.org">驻 {{ S.orgs[inst.org]?.name }}</span>
                <span class="fx">{{ d.interior.filter(it => inst.interior[it.item]).length }}/{{ d.interior.length }} 设备</span>
              </div>
              <div class="irow" v-for="it in d.interior" :key="it.item">
                <div class="ileft">
                  <span class="iname">{{ it.item }}</span>
                  <span class="fx">{{ it.unlock || it.effect }}</span>
                </div>
                <span v-if="inst.interior[it.item]" class="okk">已装</span>
                <span v-else-if="instQueued(b, it.item, idx)" class="dim">施工中</span>
                <button v-else :disabled="!canPay(it.cost)"
                        :title="canPay(it.cost) ? it.work + '人时' : '资源不足'"
                        @click="queueBuild('interior', b, it.item, idx)">
                  安装<span class="cost" v-for="[r, n] of Object.entries(it.cost)" :key="r"
                        :class="{ lack: lack(r, n) }">{{ RES_INFO[r].icon }}{{ n }}</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
#buildside { flex: 1; display: flex; flex-direction: column; min-height: 0; }
.bshead { display: flex; align-items: baseline; gap: 8px; padding: 8px 10px 5px;
          font-weight: 700; font-size: 13px; border-bottom: 1px solid var(--line); }
.bshead .sub { color: var(--dim); font-size: 11px; font-weight: 400; margin-left: auto; }
.bq { padding: 6px 10px; border-bottom: 1px solid var(--line); font-size: 11.5px;
      display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.bq .bar { flex: 1; min-width: 40px; }
.bq .qpct { color: var(--dim); font-variant-numeric: tabular-nums; }
.bq .qp { color: var(--dim); font-size: 10.5px; }
.bq .qwarn { color: var(--warn); font-size: 10.5px; }
.bslist { flex: 1; overflow-y: auto; padding: 4px 6px 10px; }
.brow { display: flex; align-items: center; gap: 6px; padding: 5px 6px; border-radius: 6px;
        font-size: 12px; cursor: pointer; }
.brow:hover { background: #ffffff08; }
.brow.open { background: #4f8cff1c; }
.brow.pre { cursor: default; opacity: .55; }
.brow .bname { font-weight: 600; }
.brow .dim { color: var(--faint); font-size: 10.5px; margin-left: auto; }
.bexp { padding: 2px 6px 8px; border-top: 1px dashed var(--line); margin-top: 1px; }
.bdesc { color: var(--dim); font-size: 11px; padding: 4px 0 6px; }
.newb { width: 100%; display: flex; align-items: center; justify-content: center;
        gap: 5px; flex-wrap: wrap; font-size: 11.5px; }
.inst { margin-top: 6px; border-top: 1px solid var(--line); padding-top: 4px; }
.ihead { display: flex; align-items: baseline; gap: 6px; padding: 2px 0; }
.ihead b { font-size: 12px; }
.ihead .fx { color: var(--dim); font-size: 10.5px; }
.irow { display: flex; align-items: center; gap: 6px; padding: 4px 0; }
.ileft { display: flex; flex-direction: column; min-width: 0; }
.ileft .iname { font-size: 11.5px; font-weight: 600; }
.ileft .fx { color: var(--dim); font-size: 10.5px; }
.irow button { margin-left: auto; flex: none; display: inline-flex; align-items: center; gap: 3px;
               font-size: 11px; padding: 2px 7px; }
.okk { margin-left: auto; color: #b8ecd0; font-size: 10.5px; background: #1f5c3e;
       border-radius: 8px; padding: 1px 7px; }
.inst .dim { margin-left: auto; color: var(--warn); font-size: 10.5px; }
</style>
