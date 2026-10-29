<script setup>
import { computed, ref } from "vue";
import { S, TERRAIN, equipOK, slotProduct, idle, feed,
         putPerson, pullPersons, putOrg, pullOrg, setProduct, delOrg } from "../sim.js";

const hall = computed(() => S.orgs.o01);
const milStaffed = computed(() => hall.value && hall.value.slots["军事"].persons.length > 0);
const militia = computed(() => S.mobilized ? S.people.filter(p => p.name.startsWith("村民")).length : 0);
const sel = computed(() => S.sel && S.orgs[S.sel] ? S.orgs[S.sel] : null);
const selSlot = computed(() => sel.value && S.selSlot ? sel.value.slots[S.selSlot] : null);
const pickPerson = ref("");
const pickOrg = ref("");
const pickProduct = ref("");
</script>

<template>
  <div id="right">
    <div id="mobil">
      <b>耕战一体</b>（动员官在位 {{ milStaffed ? "✓" : "✗" }}）<br>
      <template v-if="S.mobilized">
        <span class="val">战备中：民兵 {{ militia }} 人</span>，各组织产率减半
        <button class="ghost" @click="S.mobilized = false; feed('解除动员，回到生产', 'good')">解除动员</button>
      </template>
      <template v-else>
        平时生产、战时皆兵
        <button :disabled="!milStaffed" @click="S.mobilized = true; feed('动员令下：转入战备，产率减半', 'warn')">动员</button>
      </template>
    </div>

    <div v-if="!sel" class="lbl">
      左栏建组织/建造；点卡片选组织、点槽行操作<br><br>
      本台即组织域设计文档（迭代即改设计）：组织与建筑独立——无建筑可基础运转，
      建筑（硬装+软装设备）解锁进阶槽位与工序；同质化槽一标签多坑位（随建筑规模）；
      工厂每槽一道工序、各需设备、半成品不出厂；缺人岗位由本组织内自动借调补齐
      （原槽圈停、目标槽半透明人名+慢速圈）。
    </div>

    <template v-else>
      <h3>{{ sel.name }} <span class="tier">L{{ sel.tier }}</span></h3>
      <div class="lbl" v-if="sel.kind === 'hall'">城市根组织 · 领导＝你</div>
      <div class="lbl" v-if="sel.steps && sel.steps.length">
        工序链：{{ sel.steps.map(s => s.name + (equipOK(sel.template, s.equip) ? "✓" : "[" + s.equip + "缺]")).join(" → ") }}
      </div>
      <div class="lbl borrow" v-if="(S.borrows[sel.id] || []).length">
        自动借调中：{{ S.borrows[sel.id].map(b => b.from + "→" + b.to).join("，") }}
      </div>

      <div v-if="selSlot" class="slotsec">
        <div class="lbl">槽「{{ S.selSlot }}」{{ selSlot.def.homog
          ? `（同质化 ${selSlot.persons.length}/${selSlot.def.n} 坑，上限随建筑规模）` : ""
          }}{{ selSlot.def.role ? " · " + selSlot.def.role : "" }}</div>
        <div class="row">
          <select v-model="pickPerson">
            <option value="">选待业村民…</option>
            <option v-for="p in idle()" :key="p.id" :value="p.id">{{ p.name }}</option>
          </select>
          <button class="ghost" :disabled="selSlot.def.homog && selSlot.persons.length >= selSlot.def.n"
                  @click="putPerson(sel.id, S.selSlot, pickPerson); pickPerson = ''">派入槽</button>
        </div>
        <div class="row" v-if="selSlot.persons.length">
          <button class="ghost" @click="pullPersons(sel.id, S.selSlot)">撤出全部人员</button>
        </div>
        <div class="row">
          <select v-model="pickOrg">
            <option value="">选组织塞为机构…</option>
            <option v-for="id in S.order.filter(x => x !== sel.id && S.orgs[x])" :key="id" :value="id">
              {{ S.orgs[id].name }}
            </option>
          </select>
          <button class="ghost" @click="putOrg(sel.id, S.selSlot, pickOrg); pickOrg = ''">塞机构入槽</button>
        </div>
        <div class="row" v-if="selSlot.institution">
          <button class="ghost" @click="pullOrg(sel.id, S.selSlot)">撤出机构</button>
        </div>
        <div class="row" v-if="selSlot.def.terrain && TERRAIN[selSlot.def.terrain].products.length > 1">
          <select v-model="pickProduct" @change="setProduct(sel.id, S.selSlot, pickProduct)">
            <option v-for="p in TERRAIN[selSlot.def.terrain].products" :key="p"
                    :value="p" :selected="slotProduct(selSlot) === p">{{ p }}</option>
          </select>
          <span class="lbl" style="margin:0">产物</span>
        </div>
      </div>
      <div v-else class="lbl">点卡片槽行操作（派人顶岗/塞机构/选产物）</div>

      <div class="row" style="margin-top:8px" v-if="sel.kind !== 'hall'">
        <button class="warn ghost" @click="delOrg(sel.id)">解散组织（人员回待业）</button>
      </div>
    </template>
  </div>
</template>

<style scoped>
#right { width: 262px; flex: none; background: var(--panel); border-left: 1px solid var(--line);
         overflow-y: auto; padding: 10px; }
#right h3 { font-size: 13px; }
#right .tier { color: var(--dim); font-size: 10.5px; font-weight: 400; }
#right .row { display: flex; gap: 5px; margin: 4px 0; flex-wrap: wrap; }
#mobil { border: 1px solid var(--line); border-radius: 8px; padding: 8px;
         background: var(--panel2); margin-bottom: 10px; font-size: 12px; }
#mobil .val { color: var(--warn); font-weight: 700; }
.slotsec { border-top: 1px solid var(--line); padding-top: 8px; margin-top: 8px; }
.borrow { color: var(--acc); }
</style>
