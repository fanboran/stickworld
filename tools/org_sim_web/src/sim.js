import { reactive } from "vue";

/* ═════════ 自然地形（城市自带；采集需要对应地形在场）——本城树林/矿洞/农田都有 ═════════ */
export const TERRAIN = {
  "树林": { products: ["木材"] },
  "矿洞": { products: ["铁矿"] },
  "农田": { products: ["食物", "药材"] },   // 炼药原材料从农田来
};
/* 城市库存品目录（可进仓库）。cat：basic=基础资源 / mat=材料 / prod=制品（顶栏只放 basic，全量在仓库页）。
   铁水/毛坯/淬火件/净药材是厂内物品，不可离厂（仓库页「厂内」标签可见） */
export const RES = ["食物", "药材", "木材", "铁矿", "木板", "铁锭", "铁剑", "药水"];
export const RES_INFO = {
  "食物": { cat: "basic", icon: "🌾", src: "农田产出（无饥饿，后续绑繁衍）" },
  "药材": { cat: "basic", icon: "🌿", src: "农田产出，炼药原料" },
  "木材": { cat: "basic", icon: "🪵", src: "伐木队采自树林" },
  "铁矿": { cat: "basic", icon: "🪨", src: "采矿队采自矿洞" },
  "木板": { cat: "mat", icon: "🪚", src: "锯木坊锯解木材" },
  "铁锭": { cat: "mat", icon: "🔩", src: "外购；后期冶炼坊量产" },
  "铁剑": { cat: "prod", icon: "🗡️", src: "锻造坊开刃出品" },
  "药水": { cat: "prod", icon: "🧪", src: "药剂坊熬制" },
};
export const RES_CATS = [["basic", "基础资源"], ["mat", "材料"], ["prod", "制品"]];
export const BASIC_RES = RES.filter(r => RES_INFO[r].cat === "basic");

/* ═════════ 建筑（与组织独立：组织无建筑可基础运转；建筑解锁进阶槽位与设备工序） ═════════ */
export const BUILDINGS = {
  "市政厅": { prebuilt: true, desc: "城市根组织所在" },
  "仓库":   { prebuilt: true, desc: "资源与制品的集中存放" },
  "伐木小屋": { desc: "伐木队办公与工具场所（无它也能伐：探测/记录被禁）",
    shell: { cost: { "木材": 20 }, work: 20 }, interior: [
      { item: "办公桌椅", cost: { "木材": 6 }, work: 6, unlock: "解锁伐木队的探测/记录槽" },
      { item: "工具架",   cost: { "木板": 4 }, work: 6, effect: "伐木速率+25%" },
      { item: "额外椅子", cost: { "木板": 2 }, work: 3, effect: "木材信息联络更快" } ] },
  "锯木坊": { desc: "木材 → 木板",
    shell: { cost: { "木材": 15 }, work: 16 }, interior: [
      { item: "锯架", cost: { "木材": 8 }, work: 8, unlock: "锯解工序" } ] },
  "锻造坊": { desc: "熔炼→锻打→淬火→开刃，出铁剑（半成品不出厂）",
    shell: { cost: { "木材": 25 }, work: 24 }, interior: [
      { item: "熔炉", cost: { "木材": 10, "木板": 4 }, work: 10, unlock: "熔炼工序（铁矿+木材→铁水）" },
      { item: "铁砧", cost: { "铁矿": 4 }, work: 8, unlock: "锻打工序（铁水/铁锭→毛坯）" },
      { item: "水槽", cost: { "木材": 6 }, work: 5, unlock: "淬火工序（毛坯→淬火件）" },
      { item: "磨石", cost: { "铁矿": 2 }, work: 5, unlock: "开刃工序（淬火件→铁剑）" } ] },
  "药剂坊": { desc: "药材 → 净药材 → 药水",
    shell: { cost: { "木材": 12 }, work: 12 }, interior: [
      { item: "切药刀", cost: { "铁矿": 1 }, work: 4, unlock: "炮制工序（药材→净药材）" },
      { item: "药炉",   cost: { "木材": 8 }, work: 6, unlock: "熬制工序（净药材→药水）" } ] },
};

/* ═════════ 组织模板（同质化槽：一标签多坑位；异质化工序：每槽一道工序各需设备） ═════════ */
export const ORGS = {
  "运输队": { host: "搬运", slots: [
      { fn: "库管", n: 1, role: "仓库进出账目（在岗搬运才运转）" },
      { fn: "搬运", n: 5, homog: true, role: "同质化×5，坑位上限随仓库规模" } ] },
  "建造队": { host: "施工", slots: [
      { fn: "施工", n: 4, homog: true, role: "硬装与软装都干" } ] },
  "伐木队": { host: "采集", slots: [
      { fn: "伐木", n: 4, homog: true, terrain: "树林" },
      { fn: "木材信息", n: 1, role: "堆存需转运时通报运输队（人手/地点）——可被本队自动借调" },
      { fn: "探测", n: 1, req: { b: "伐木小屋", item: "办公桌椅" }, role: "木材资源探测" },
      { fn: "记录", n: 1, req: { b: "伐木小屋", item: "办公桌椅" }, role: "木材台账" } ] },
  "采矿队": { host: "采集", slots: [
      { fn: "挖矿", n: 4, homog: true, terrain: "矿洞" },
      { fn: "矿石信息", n: 1, role: "与运输队联络（可被借调）" } ] },
  "农垦队": { host: "采集", slots: [
      { fn: "耕作", n: 4, homog: true, terrain: "农田", role: "产物可选：食物/药材" } ] },
  "锯木坊": { host: "制造", slots: [ { fn: "锯解", n: 2, homog: true, step: 0 } ],
      steps: [ { name: "锯解", equip: "锯架", inCity: { "木材": 1 }, outCity: { "木板": 1 } } ] },
  "锻造坊": { host: "制造", slots: [
      { fn: "熔炼", n: 1, step: 0 }, { fn: "锻打", n: 1, step: 1 },
      { fn: "淬火", n: 1, step: 2 }, { fn: "开刃", n: 1, step: 3 } ],
      steps: [   // 古代冶炼/锻造分工；半成品为厂内物品不可离厂；锻打可吃铁水也可吃外购铁锭
        { name: "熔炼", equip: "熔炉", inCity: { "铁矿": 1, "木材": 1 }, wip: "铁水" },
        { name: "锻打", equip: "铁砧", wipIn: "铁水", altCity: { "铁锭": 1 }, wip: "毛坯" },
        { name: "淬火", equip: "水槽", wipIn: "毛坯", wip: "淬火件" },
        { name: "开刃", equip: "磨石", wipIn: "淬火件", outCity: { "铁剑": 1 } } ] },
  "药剂坊": { host: "制造", slots: [ { fn: "炮制", n: 1, step: 0 }, { fn: "熬制", n: 1, step: 1 } ],
      steps: [
        { name: "炮制", equip: "切药刀", inCity: { "药材": 1 }, wip: "净药材" },
        { name: "熬制", equip: "药炉", wipIn: "净药材", outCity: { "药水": 1 } } ] },
  /* 后期 */
  "冶炼坊": { host: "制造", late: true, slots: [ { fn: "冶炼", n: 1 } ], steps: [] },
  "常备军": { host: "军事", late: true, slots: [ { fn: "军事", n: 1 }, { fn: "训练", n: 1 } ] },
  "训练营": { host: "军事", late: true, slots: [ { fn: "训练", n: 1 } ] },
  "科研院": { host: "科研", late: true, slots: [ { fn: "科研", n: 1 } ] },
};
export const HALL_SLOT_KEYS = ["领导", "军事", "行政", "采集", "搬运", "施工", "制造", "科研"];
export const LATE_COST = { "常备军": { res: { "食物": 50 } }, "训练营": { res: { "木材": 15 } },
                           "科研院": { res: { "木板": 10 }, prereq: "在编有人会占位组织技能01" } };
/* 建组织面板的系统分类（序＝市政厅槽位序；组织类型会越来越多，靠分类+折叠承载） */
export const ORG_CATS = (() => {
  const order = ["采集", "搬运", "施工", "制造", "军事", "科研"];
  const m = new Map(order.map(k => [k, []]));
  for (const [name, t] of Object.entries(ORGS)) {
    if (!m.has(t.host)) m.set(t.host, []);
    m.get(t.host).push(name);
  }
  return [...m].map(([cat, names]) => ({ cat, names }));
})();

/* ═════════ 状态（响应式单例） ═════════ */
export const S = reactive({
  hours: 0, speed: 0, seq: { p: 0, o: 0 },
  people: [], orgs: {}, order: [],
  res: {}, buf: {}, wip: {}, buildings: {}, buildOrders: [],
  mobilized: false, borrows: {},
  sel: null, selSlot: null, feed: [], rates: {},
  knobs: { gather: 0.8, haul: 1.2, craft: 0.6, uninfo: 0.5, buf: 40, cap: 250 },
});

export function reset() {
  const fresh = {
    hours: 0, speed: 0, seq: { p: 0, o: 0 },
    people: [], orgs: {}, order: [],
    res: { "食物": 50, "药材": 0, "木材": 40, "铁矿": 10, "木板": 5, "铁锭": 4, "铁剑": 0, "药水": 0 },
    buf: {}, wip: {}, buildings: {}, buildOrders: [],   // buildings[类型]＝实例数组（存在即硬装完成）
    mobilized: false, borrows: {},
    sel: null, selSlot: null, feed: [], rates: {},
  };
  Object.assign(S, fresh);
  for (const b of Object.keys(BUILDINGS))
    S.buildings[b] = BUILDINGS[b].prebuilt ? [{ interior: {} }] : [];
  for (const [site, t] of Object.entries(TERRAIN))
    for (const p of t.products) S.buf[site + "|" + p] = 0;
  const hall = addOrgRaw("市政厅", 3, "hall");
  for (const key of HALL_SLOT_KEYS)
    hall.slots[key] = { def: { fn: key, n: 1, role: "" }, persons: [], institution: "", product: "" };
  addPersonRaw("你"); S.people[0].org = "o01"; hall.slots["领导"].persons = ["p01"];
  addPersonRaw("动员官"); S.people[1].org = "o01"; hall.slots["军事"].persons = ["p02"];
  for (let i = 0; i < 12; i++) addPersonRaw("村民");
  feed("开局：出生城自带市政厅与仓库，树林/矿洞/农田三类地形都在。耕战一体——动员官挂军事槽（无饥饿系统）");
}

/* ── 工具 ── */
export const CIRC = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"];   // 建筑实例枚举（区分座，非命名）
export const person = pid => S.people.find(p => p.id === pid);
export const idle = () => S.people.filter(p => !p.org);
export const capTotal = () => S.knobs.cap;
export const resTotal = () => RES.reduce((a, r) => a + S.res[r], 0);
/* 建筑按座计（同型可多座，每座独立软装）。设备解锁=城内存在任一座装了该设备
   （组织↔具体建筑实例的入驻绑定是后续设计，先按存在语义算） */
export const equipOK = (b, item) => (S.buildings[b] || []).some(inst => inst.interior[item]);
export function addPersonRaw(name) {
  S.seq.p += 1;
  S.people.push({ id: "p" + String(S.seq.p).padStart(2, "0"), name, org: "" });
}
export function addOrgRaw(name, tier, kind) {
  S.seq.o += 1;
  const id = "o" + String(S.seq.o).padStart(2, "0");
  const tpl = ORGS[name] || {};
  S.orgs[id] = { id, name, tier, kind: kind || "", template: name, slots: {}, steps: tpl.steps || [] };
  if (kind !== "hall")
    for (const def of (tpl.slots || []))
      S.orgs[id].slots[def.fn] = { def, persons: [], institution: "", product: "" };
  S.order.push(id);
  return S.orgs[id];
}
export function feed(text, cls) {
  S.feed.push({ t: S.hours, text, cls: cls || "" });
  if (S.feed.length > 160) S.feed.shift();
}
export function membersOf(o) {
  let n = 0; for (const s of Object.values(o.slots)) n += s.persons.length; return n;
}
/* 厂内半成品清单（各厂 WIP 汇总，仓库页「厂内」标签用） */
export function wipList() {
  const rows = [];
  for (const o of S.order.map(x => S.orgs[x]).filter(Boolean))
    for (const [item, qty] of Object.entries(S.wip[o.id] || {}))
      if (qty > 0.001) rows.push({ org: o.name, item, qty });
  return rows;
}
/* 在岗施工人力（建造队等组织「施工」槽在岗人数） */
export function buildWorkers() {
  let w = 0;
  for (const o of Object.values(S.orgs)) { const s = o.slots["施工"]; if (s) w += s.persons.length; }
  return w;
}
export function wipOf(o) { return S.wip[o.id] || (S.wip[o.id] = {}); }
export const bufKey = (site, product) => site + "|" + product;
export function costStr(c) { return Object.entries(c).map(([r, n]) => n + r).join(" "); }
export function canPay(c) { return Object.entries(c).every(([r, n]) => S.res[r] >= n); }
export function pay(c) { for (const [r, n] of Object.entries(c)) S.res[r] -= n; }
export function stepDesc(st) {
  const inn = st.inCity ? Object.entries(st.inCity).map(([r, x]) => x + r).join("+")
    : (st.wipIn || "") + (st.altCity ? "/" + Object.keys(st.altCity).join("") : "");
  return `${inn}→${st.outCity ? Object.keys(st.outCity).join("") : st.wip}`;
}
export function orgDesc(name) {
  const t = ORGS[name];
  if (t.steps && t.steps.length) return t.steps.map(stepDesc).join("→");
  return (t.slots || []).map(s => s.fn + (s.homog ? "×" + s.n : "")).join("/");
}
export function slotProduct(slot) {
  const list = TERRAIN[slot.def.terrain].products;
  return list.includes(slot.product) ? slot.product : list[0];
}

/* ═════════ 经济推进 ═════════ */
export function advance(dt) {
  const K = S.knobs;
  const mult = S.mobilized ? 0.5 : 1;
  const flow = {}; for (const r of RES) flow[r] = 0;
  S.borrows = {};
  // ① 信息通报与借调（先于采集：被借调者本拍离岗）
  const notified = {};
  const awayFrom = {};
  for (const o of Object.values(S.orgs)) {
    const workSlots = Object.values(o.slots).filter(s => s.def.terrain);
    if (!workSlots.length) continue;
    const infoSlots = Object.values(o.slots).filter(s => /信息/.test(s.def.fn));
    for (const ws of workSlots) {
      const key = bufKey(ws.def.terrain, slotProduct(ws));
      const needNotify = S.buf[key] > K.buf * 0.3;
      if (!needNotify) { notified[key] = true; continue; }
      const staffed = infoSlots.find(s => s.persons.length);
      if (staffed) { notified[key] = true; continue; }
      if (infoSlots.length && ws.persons.length) {
        notified[key] = true;
        (S.borrows[o.id] ||= []).push({ from: ws.def.fn, to: infoSlots[0].def.fn });
        awayFrom[o.id + "|" + ws.def.fn] = (awayFrom[o.id + "|" + ws.def.fn] || 0) + 1;
      } else notified[key] = false;
    }
  }
  // ② 采集（产出进场地缓冲堆，不经采集队之手——运输的物理意义）
  for (const o of Object.values(S.orgs)) {
    for (const slot of Object.values(o.slots)) {
      const d = slot.def;
      if (!d.terrain) continue;
      const away = awayFrom[o.id + "|" + d.fn] || 0;
      const w = Math.max(0, slot.persons.length - away);
      if (!w) continue;
      let rate = K.gather;
      if (d.terrain === "树林" && equipOK("伐木小屋", "工具架")) rate *= 1.25;
      const amt = rate * w * mult * dt;
      const key = bufKey(d.terrain, slotProduct(slot));
      const room = K.buf - S.buf[key];
      const got = Math.min(amt, Math.max(0, room));
      S.buf[key] += got; flow[slotProduct(slot)] += got;
    }
  }
  // ③ 搬运（库管在岗才运转；被通报场地全速，未通报打折扣）
  let haulers = 0, keeper = false;
  for (const o of Object.values(S.orgs)) {
    const kp = o.slots["库管"]; if (kp && kp.persons.length) keeper = true;
    const hp = o.slots["搬运"]; if (hp) haulers += hp.persons.length;
  }
  if (keeper && haulers > 0) {
    const cap = K.haul * haulers * mult * dt;
    const keys = Object.keys(S.buf).filter(key2 => S.buf[key2] > 0.001);
    const totalBuf = keys.reduce((a, key2) => a + S.buf[key2], 0);
    const move = Math.min(cap, totalBuf, Math.max(0, capTotal() - resTotal()));
    if (move > 0) for (const key2 of keys) {
      const part = S.buf[key2] / totalBuf;
      const disc = notified[key2] === false ? K.uninfo : 1;
      const m = move * part * disc;
      S.buf[key2] -= m;
      S.res[key2.split("|")[1]] += m;
    }
  }
  // ④ 工厂：每槽一道工序、每工序需设备；工时在可开工工序间均摊——一人厂=独轮回全工序（慢但转）
  for (const o of Object.values(S.orgs)) {
    const steps = o.steps || [];
    if (!steps.length) continue;
    const workers = membersOf(o);
    if (!workers) continue;
    const runnable = steps.map(st => {
      if (!equipOK(o.template, st.equip)) return false;
      if (st.inCity) return Object.entries(st.inCity).every(([r, n]) => S.res[r] >= 0.001);
      if (st.wipIn && (wipOf(o)[st.wipIn] || 0) > 0.001) return true;
      if (st.altCity) return Object.entries(st.altCity).every(([r, n]) => S.res[r] >= 0.001);
      return false;
    });
    const runCount = runnable.filter(Boolean).length;
    if (!runCount) continue;
    const perStep = workers / runCount;
    for (let i = 0; i < steps.length; i++) {
      if (!runnable[i]) continue;
      const st = steps[i];
      const slot = o.slots[st.name];
      if (slot && !slot.persons.length) {
        const src = Object.values(o.slots).find(s => s.persons.length);
        if (src) (S.borrows[o.id] ||= []).push({ from: src.def.fn, to: st.name });
      }
      const want = K.craft * perStep * mult * dt;
      let produced = 0;
      if (st.inCity) {
        const can = Math.min(want, ...Object.entries(st.inCity).map(([r, n]) => S.res[r] / n));
        if (can > 0) {
          for (const [r, n] of Object.entries(st.inCity)) { S.res[r] -= n * can; flow[r] -= n * can; }
          produced = can;
        }
      }
      if (st.wipIn) {
        const inner = Math.min(want, wipOf(o)[st.wipIn] || 0);
        wipOf(o)[st.wipIn] -= inner;
        let outer = 0;
        if (st.altCity) {
          const can = Math.min(want - inner, ...Object.entries(st.altCity).map(([r, n]) => S.res[r] / n));
          if (can > 0) { for (const [r, n] of Object.entries(st.altCity)) { S.res[r] -= n * can; flow[r] -= n * can; }
            outer = can; }
        }
        produced = inner + outer;
      }
      if (produced > 0) {
        if (st.wip) wipOf(o)[st.wip] = (wipOf(o)[st.wip] || 0) + produced;
        else if (st.outCity) for (const [r, n] of Object.entries(st.outCity)) { S.res[r] += n * produced; flow[r] += n * produced; }
      }
    }
  }
  // ⑤ 施工队列
  if (S.buildOrders.length) {
    let w = 0;
    for (const o of Object.values(S.orgs)) { const s = o.slots["施工"]; if (s) w += s.persons.length; }
    if (w) {
      const ord = S.buildOrders[0];
      ord.done += w * mult * dt;
      if (ord.done >= ord.work) {
        if (ord.kind === "shell") S.buildings[ord.b].push({ interior: {} });
        else S.buildings[ord.b][ord.idx].interior[ord.item] = true;
        const tag = ord.kind === "shell" ? `第${S.buildings[ord.b].length}座硬装落成` : `${CIRC[ord.idx]}·${ord.item}装好`;
        feed(`${ord.b} ${tag}（建造队交付）`, "good");
        S.buildOrders.shift();
      }
    }
  }
  // rates 语义=每时净流量（本拍增量按 dt 归一），供顶栏/仓库瓦片显示
  for (const r of RES) flow[r] /= dt;
  S.rates = flow;
}

/* ═════════ 玩家操作 ═════════ */
export function createOrg(name) {
  const cost = LATE_COST[name] || {};
  if (cost.res && !canPay(cost.res)) { feed(`建「${name}」资源不足（${costStr(cost.res)}）`, "bad"); return; }
  if (cost.prereq) { feed(`「${name}」明面前提未满足：${cost.prereq}`, "bad"); return; }
  if (cost.res) pay(cost.res);
  const o = addOrgRaw(name, 2, "");
  const hostKey = ORGS[name].host, hall = S.orgs.o01;
  let placed = false;
  if (hall && hall.slots[hostKey]) {
    const occ = hall.slots[hostKey].institution ? S.orgs[hall.slots[hostKey].institution] : null;
    if (!occ) { hall.slots[hostKey].institution = o.id; placed = true;
      feed(`组建 ${o.name}，入驻市政厅「${hostKey}」槽`, "good"); }
    else if (name === "训练营" && occ.slots["训练"] && !occ.slots["训练"].institution) {
      occ.slots["训练"].institution = o.id; placed = true;
      feed(`组建 ${o.name}，入驻 ${occ.name} 的「训练」槽（军事职能下沉）`, "good"); }
  }
  if (!placed) feed(`组建 ${o.name}（${hostKey}槽被占——可经槽面板手动入驻）`, "bad");
  S.sel = o.id; S.selSlot = null;
}
export function queueBuild(kind, b, item, idx) {
  const d = BUILDINGS[b];
  const it = item ? d.interior.find(x => x.item === item) : null;
  const cost = item ? it.cost : d.shell.cost;
  const work = item ? it.work : d.shell.work;
  if (kind === "interior") {
    const inst = S.buildings[b][idx];
    if (!inst) { feed(`${b} 第${idx + 1}座尚不存在`, "bad"); return; }
    if (inst.interior[item]) { feed(`${b} 第${idx + 1}座的${item}已装`, "bad"); return; }
    if (S.buildOrders.some(o => o.b === b && o.item === item && o.idx === idx)) {
      feed(`${b} 第${idx + 1}座的${item}已在施工队列`, "bad"); return;
    }
  }
  if (!canPay(cost)) { feed(`${b} 施工资源不足（${costStr(cost)}）`, "bad"); return; }
  pay(cost);
  S.buildOrders.push({ kind, b, item: item || "", idx: idx ?? -1, work, done: 0 });
  const instTag = kind === "interior" ? CIRC[idx] + "·" : "";
  feed(`开工 ${b}${kind === "shell" ? "·新一座硬装" : "·" + instTag + item}（${costStr(cost)} 已扣）`, "good");
}
export function delOrg(orgId) {
  const o = S.orgs[orgId]; if (!o) return;
  for (const slot of Object.values(o.slots)) for (const pid of slot.persons) person(pid).org = "";
  delete S.orgs[orgId]; S.order = S.order.filter(x => x !== orgId);
  for (const other of Object.values(S.orgs))
    for (const slot of Object.values(other.slots)) if (slot.institution === orgId) slot.institution = "";
  feed(`解散 ${o.name}（人员回待业）`);
  if (S.sel === orgId) { S.sel = null; S.selSlot = null; }
}
export function putPerson(orgId, fn, pid) {
  const o = S.orgs[orgId]; if (!o || !o.slots[fn] || !pid) return;
  const slot = o.slots[fn], d = slot.def;
  if (d.homog && slot.persons.length >= d.n) { feed(`「${fn}」坑位已满（${d.n}，随建筑规模变动）`, "bad"); return; }
  if (slot.institution) { feed(`${o.name}「${fn}」撤出机构，改为人员顶岗`); slot.institution = ""; }
  slot.persons.push(pid); person(pid).org = orgId;
  feed(`${person(pid).name} 入 ${o.name}「${fn}」槽（在编）`, "good");
}
export function pullPersons(orgId, fn) {
  const slot = S.orgs[orgId]?.slots[fn]; if (!slot) return;
  for (const pid of slot.persons) person(pid).org = "";
  slot.persons = [];
}
export function putOrg(orgId, fn, instId) {
  const o = S.orgs[orgId]; if (!o || !o.slots[fn] || !instId) return;
  if (createsCycle(orgId, instId)) { feed("嵌套成环：拒绝", "bad"); return; }
  o.slots[fn].persons = [];
  o.slots[fn].institution = instId;
  feed(`${S.orgs[instId].name} 整体塞进 ${o.name} 的「${fn}」槽（机构入驻）`, "nest");
}
export function pullOrg(orgId, fn) {
  const slot = S.orgs[orgId]?.slots[fn]; if (slot) slot.institution = "";
}
export function setProduct(orgId, fn, product) {
  const slot = S.orgs[orgId]?.slots[fn]; if (slot) slot.product = product;
}
export function select(orgId, fn) { S.sel = orgId; S.selSlot = fn || null; }
export function createsCycle(hostId, instId) {
  const seen = new Set(); const q = [instId];
  while (q.length) {
    const cur = q.shift();
    if (cur === hostId) return true;
    if (seen.has(cur)) continue; seen.add(cur);
    for (const slot of Object.values(S.orgs[cur]?.slots || {}))
      if (slot.institution) q.push(slot.institution);
  }
  return false;
}

reset();
