import { reactive } from "vue";

/* ═════════ 自然地形（城市自带；采集需要对应地形在场）——本城树林/矿洞/农田都有 ═════════ */
export const TERRAIN = {
  "树林": { products: ["木材"] },
  "矿洞": { products: ["铁矿"] },
  "农田": { products: ["粮", "药材"] },   // 炼药原材料从农田来
};
/* 城市库存品目录（可进仓库）。cat：basic=基础资源 / mat=材料 / prod=制品（顶栏只放 basic，全量在仓库页）。
   口径（05-经济系统 §一）：进食是可选增益、不设「食物」资源——农田产物叫粮（战粮类增益品原料）。
   铁水/毛坯/淬火件/净药材是厂内物品，不可离厂（仓库页「厂内」标签可见） */
export const RES = ["粮", "药材", "木材", "铁矿", "木板", "铁锭", "铁剑", "药水"];
export const RES_INFO = {
  "粮":   { cat: "basic", icon: "🌾", src: "农田产出（进食可选增益、无饥饿；后续绑繁衍）" },
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

/* ═════════ 组织模板。host＝可入驻的槽名（选中空槽即弹出该槽可构筑的子组织，可递归）；
   pos＝岗位用人类型：run=有人才能运行（无人停摆）· flex=需人运行但不必时刻有人（可借调顶岗）
   · any=至少一人启动、人数越多越快 · opt=有无人都行，无人只是缺失该功能；
   role＝「放人/放组织解锁什么」的能力标注；bldg＝需进驻的建筑类型（03 §一）═════════ */
export const ORGS = {
  "生产局": { host: "生产", slots: [
      { fn: "采集", n: 1, pos: "run", role: "放人解锁泛采集兜底（0.4/人时）；放采集队统筹三线" },
      { fn: "建造", n: 1, pos: "run", role: "放人解锁亲自督造；放工程队系统化施工" },
      { fn: "制造", n: 1, pos: "run", role: "放人解锁制造跟单；放工坊统筹各厂" } ] },
  "采集队": { host: "采集", slots: [
      { fn: "伐木", n: 1, pos: "run", role: "放伐木队专精伐木线" },
      { fn: "采矿", n: 1, pos: "run", role: "放采矿队专精采矿线" },
      { fn: "农垦", n: 1, pos: "run", role: "放农垦队专精农耕线" } ] },
  "工坊": { host: "制造", slots: [
      { fn: "锯木", n: 1, pos: "run", role: "放锯木坊制木板" },
      { fn: "锻造", n: 1, pos: "run", role: "放锻造坊制铁剑" },
      { fn: "制药", n: 1, pos: "run", role: "放药剂坊制药水" },
      { fn: "冶炼", n: 1, pos: "run", role: "放冶炼坊量产铁锭（后期）" } ] },
  "工程队": { host: "建造", slots: [
      { fn: "测量", n: 1, pos: "opt", role: "放人解锁施工提效：效率×1.15（放线准少返工）" },
      { fn: "施工", n: 4, homog: true, pos: "any", role: "至少1人开工、越多越快；硬装软装都干" },
      { fn: "质检", n: 1, pos: "opt", role: "放人解锁工序核验（机制后续）" } ] },
  "运输队": { host: "运输", slots: [
      { fn: "调度", n: 1, pos: "opt", role: "放人解锁运输计划：未通报场地搬运折扣 ×0.5→×0.7" },
      { fn: "库管", n: 1, pos: "run", role: "放人才有搬运运转（仓库进出账目）" },
      { fn: "搬运", n: 5, homog: true, pos: "any", role: "至少1人启动、越多运力越大；坑位随仓库规模" } ] },
  "伐木队": { host: "伐木", bldg: "伐木小屋", slots: [
      { fn: "伐木", n: 4, homog: true, pos: "any", terrain: "树林", role: "至少1人开工、越多越快" },
      { fn: "木材信息", n: 1, pos: "flex", role: "放人解锁堆存通报（运输队按需来人）——可被本队借调顶岗" },
      { fn: "探测", n: 1, pos: "opt", req: { b: "伐木小屋", item: "办公桌椅" }, role: "放人解锁木材资源探测" },
      { fn: "记录", n: 1, pos: "opt", req: { b: "伐木小屋", item: "办公桌椅" }, role: "放人解锁木材台账" } ] },
  "采矿队": { host: "采矿", slots: [
      { fn: "挖矿", n: 4, homog: true, pos: "any", terrain: "矿洞", role: "至少1人开工、越多越快" },
      { fn: "矿石信息", n: 1, pos: "flex", role: "放人解锁堆存通报——可被本队借调顶岗" } ] },
  "农垦队": { host: "农垦", slots: [
      { fn: "耕作", n: 4, homog: true, pos: "any", terrain: "农田", role: "至少1人开工、越多越快；产物在组织面板选" } ] },
  "锯木坊": { host: "锯木", bldg: "锯木坊", slots: [ { fn: "锯解", n: 2, homog: true, pos: "flex", step: 0, role: "工序岗：有人才运转，可借调轮转（一人厂独轮回）" } ],
      steps: [ { name: "锯解", equip: "锯架", inCity: { "木材": 1 }, outCity: { "木板": 1 } } ] },
  "锻造坊": { host: "锻造", bldg: "锻造坊", slots: [
      { fn: "熔炼", n: 1, pos: "flex", step: 0, role: "工序岗——可借调轮转" },
      { fn: "锻打", n: 1, pos: "flex", step: 1, role: "工序岗——可借调轮转" },
      { fn: "淬火", n: 1, pos: "flex", step: 2, role: "工序岗——可借调轮转" },
      { fn: "开刃", n: 1, pos: "flex", step: 3, role: "工序岗——可借调轮转" } ],
      steps: [   // 古代冶炼/锻造分工；半成品为厂内物品不可离厂；锻打原料偏好见组织面板
        { name: "熔炼", equip: "熔炉", inCity: { "铁矿": 1, "木材": 1 }, wip: "铁水" },
        { name: "锻打", equip: "铁砧", wipIn: "铁水", altCity: { "铁锭": 1 }, wip: "毛坯" },
        { name: "淬火", equip: "水槽", wipIn: "毛坯", wip: "淬火件" },
        { name: "开刃", equip: "磨石", wipIn: "淬火件", outCity: { "铁剑": 1 } } ] },
  "药剂坊": { host: "制药", bldg: "药剂坊", slots: [
      { fn: "炮制", n: 1, pos: "flex", step: 0, role: "工序岗——可借调轮转" },
      { fn: "熬制", n: 1, pos: "flex", step: 1, role: "工序岗——可借调轮转" } ],
      steps: [
        { name: "炮制", equip: "切药刀", inCity: { "药材": 1 }, wip: "净药材" },
        { name: "熬制", equip: "药炉", wipIn: "净药材", outCity: { "药水": 1 } } ] },
  /* 后期 */
  "冶炼坊": { host: "冶炼", bldg: "冶炼坊", late: true, slots: [ { fn: "冶炼", n: 1, pos: "flex", role: "工序岗——可借调轮转" } ], steps: [] },
  "常备军": { host: "军事", late: true, slots: [
      { fn: "军事", n: 1, pos: "run", role: "放人解锁军事指挥（在编即可动员）" },
      { fn: "训练", n: 1, pos: "run", role: "放训练营解锁训练职能" } ] },
  "训练营": { host: "训练", late: true, slots: [ { fn: "训练", n: 1, pos: "run", role: "放人解锁对编制组织的训练" } ] },
  "科研院": { host: "科研", late: true, slots: [
      { fn: "课题管理", n: 1, pos: "run", role: "放人解锁选题立项与资源分配" },
      { fn: "实验", n: 3, homog: true, pos: "any", role: "研究员越多产出越快——新技能长在本人身上" },
      { fn: "文献记录", n: 1, pos: "opt", role: "放人解锁台账与资料（技能图谱呈报源）" } ] },
};
export const HALL_SLOT_KEYS = ["市长", "军事", "生产", "运输", "科研"];
export const LATE_COST = { "常备军": { res: { "粮": 50 } }, "训练营": { res: { "木材": 15 } },
                           "科研院": { res: { "木板": 10 }, prereq: "在编有人会占位组织技能01" } };
/* 空槽的可构筑候选（按槽名匹配 host——组织树即构筑树；别名＝放弃统筹层直挂单线的路径偏好） */
export const SLOT_ALIAS = { "采集": ["伐木队", "采矿队", "农垦队"], "制造": ["锯木坊", "锻造坊", "药剂坊"] };
export const slotCandidates = fn => {
  const base = Object.entries(ORGS).filter(([, t]) => t.host === fn).map(([n]) => n);
  return [...base, ...(SLOT_ALIAS[fn] || []).filter(n => !base.includes(n))];
};
/* 组织控制面板选项（实际游戏为各组织专属的复杂精美 UI，sim 只模拟基础功能；
   选不同机构＝功能实现路径的偏好，如同计划 or 市场） */
export const ORG_PANELS = {
  "常备军": [ { key: "兵役制度", choices: [["动员兵役", "耕战一体：战时集结，动员时产率减半"],
                                            ["常备兵役", "职业兵维持耗粮（后续），动员不减产率"]] } ],
  "运输队": [ { key: "载具", choices: [["人力搬运", "1.2/人时"], ["手推车", "1.8/人时（需造车，暂直开）"]] } ],
  "锻造坊": [ { key: "锻打原料", choices: [["铁水优先", "自炼为主，外购补口"],
                                            ["铁锭优先", "外购为主，省下燃料"]] } ],
  "农垦队": [ { key: "产物", choices: [["粮", "战粮类增益品原料"], ["药材", "炼药原料"]] } ],
};
/* 建不了的原因（拒止反馈落在按钮态上）：前提→资源，与构筑同序 */
export function createBlocked(name) {
  const cost = LATE_COST[name];
  if (!cost) return "";
  if (cost.prereq) return "明面前提未满足：" + cost.prereq;
  if (!canPay(cost.res)) return "资源不足：" + costStr(cost.res);
  return "";
}

/* ═════════ 状态（响应式单例） ═════════ */
export const S = reactive({
  hours: 0, speed: 0, seq: { p: 0, o: 0 },
  people: [], orgs: {}, order: [],
  res: {}, buf: {}, wip: {}, buildings: {}, buildOrders: [],
  mobilized: false, borrows: {},
  sel: null, selSlot: null, feed: [], rates: {},
  knobs: { gather: 0.8, deptGather: 0.4, haul: 1.2, craft: 0.6, uninfo: 0.5, buf: 40, cap: 250 },
});

export function reset() {
  const fresh = {
    hours: 0, speed: 0, seq: { p: 0, o: 0 },
    people: [], orgs: {}, order: [],
    res: { "粮": 80, "药材": 0, "木材": 60, "铁矿": 20, "木板": 10, "铁锭": 4, "铁剑": 0, "药水": 0 },
    buf: {}, wip: {}, buildings: {}, buildOrders: [],   // buildings[类型]＝实例数组（存在即硬装完成）
    mobilized: false, borrows: {},
    sel: null, selSlot: null, feed: [], rates: {},
  };
  Object.assign(S, fresh);
  for (const b of Object.keys(BUILDINGS))
    S.buildings[b] = BUILDINGS[b].prebuilt ? [{ interior: {}, org: "" }] : [];
  for (const [site, t] of Object.entries(TERRAIN))
    for (const p of t.products) S.buf[site + "|" + p] = 0;
  /* 完全体展示：城市级别能达到的完整构筑（构筑变体之一，全自动设计样板）——
     建筑先行落成并配齐设备，组织随后组建即自动进驻对应实例 */
  const inst = (b, ...items) => {
    const it = {}; for (const x of items) it[x] = true;
    S.buildings[b].push({ interior: it, org: "" });
  };
  inst("伐木小屋", "办公桌椅", "工具架", "额外椅子");
  inst("锯木坊", "锯架");
  inst("锻造坊", "熔炉", "铁砧", "水槽", "磨石");
  inst("药剂坊", "切药刀", "药炉");
  addPersonRaw("你");
  addPersonRaw("动员官");
  for (let i = 0; i < 26; i++) addPersonRaw("村民");
  const hall = addOrgRaw("市政厅", 3, "hall");
  for (const key of HALL_SLOT_KEYS)
    hall.slots[key] = { def: { fn: key, n: 1, pos: "run", role: key === "市长" ? "放你（城市根）" : "放人或构筑组织，解锁该系统运转" }, persons: [], institution: "", product: "" };
  const vill = () => S.people.filter(p => !p.org).map(p => p.id);
  const place = (container, fn, org) => { container.slots[fn].institution = org.id; };
  const staff = (org, fn, n, ids) => {
    for (const pid of ids.slice(0, n)) { org.slots[fn].persons.push(pid); person(pid).org = org.id; }
  };
  /* 组织树：市政厅 → 生产局（采集队→伐木/采矿/农垦 · 工程队 · 工坊→锯木/锻造/药剂）· 运输队 · 常备军（训练=训练营）· 科研院 */
  hall.slots["市长"].persons = ["p01"]; S.people[0].org = hall.id;
  const dept = addOrgRaw("生产局", 2, ""); place(hall, "生产", dept);
  const gather = addOrgRaw("采集队", 2, ""); place(dept, "采集", gather);
  const works = addOrgRaw("工坊", 2, ""); place(dept, "制造", works);
  const eng = addOrgRaw("工程队", 2, ""); place(dept, "建造", eng);
  const lumber = addOrgRaw("伐木队", 2, ""); place(gather, "伐木", lumber);
  const mining = addOrgRaw("采矿队", 2, ""); place(gather, "采矿", mining);
  const farm = addOrgRaw("农垦队", 2, ""); place(gather, "农垦", farm);
  const sawmill = addOrgRaw("锯木坊", 2, ""); place(works, "锯木", sawmill);
  const forge = addOrgRaw("锻造坊", 2, ""); place(works, "锻造", forge);
  const pharmacy = addOrgRaw("药剂坊", 2, ""); place(works, "制药", pharmacy);
  const haul = addOrgRaw("运输队", 2, ""); place(hall, "运输", haul);
  const army = addOrgRaw("常备军", 2, ""); place(hall, "军事", army);
  army.slots["军事"].persons = ["p02"]; S.people[1].org = army.id;
  const camp = addOrgRaw("训练营", 2, ""); place(army, "训练", camp);
  const sci = addOrgRaw("科研院", 2, ""); place(hall, "科研", sci);
  /* 满员运转 */
  let q = vill();
  staff(lumber, "伐木", 2, q); staff(mining, "挖矿", 2, q.slice(2));
  staff(farm, "耕作", 2, q.slice(4));
  staff(haul, "调度", 1, q.slice(6)); staff(haul, "库管", 1, q.slice(7)); staff(haul, "搬运", 3, q.slice(8));
  staff(eng, "测量", 1, q.slice(11)); staff(eng, "施工", 2, q.slice(12));
  staff(forge, "熔炼", 1, q.slice(14)); staff(forge, "锻打", 1, q.slice(15));
  staff(forge, "淬火", 1, q.slice(16)); staff(forge, "开刃", 1, q.slice(17));
  staff(sawmill, "锯解", 1, q.slice(18));
  staff(pharmacy, "炮制", 1, q.slice(19));
  staff(sci, "课题管理", 1, q.slice(20)); staff(sci, "实验", 2, q.slice(21)); staff(sci, "文献记录", 1, q.slice(23));
  feed("完全体展示：城市级完整构筑样板（变体之一）——生产局下辖采集队/工程队/工坊逐层递归，运输/常备军(训练营)/科研院并列。选中空槽可派人或构筑子组织");
}

/* ── 工具 ── */
export const CIRC = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"];   // 建筑实例枚举（区分座，非命名）
export const person = pid => S.people.find(p => p.id === pid);
export const idle = () => S.people.filter(p => !p.org);
export const capTotal = () => S.knobs.cap;
export const resTotal = () => RES.reduce((a, r) => a + S.res[r], 0);
/* 建筑按座计（同型可多座，每座独立软装）。组织进驻一座对应建筑实例（03 §一：
   组织所在的建筑需具备它需要的设施；换址留待后续设计）——设备/解锁按**本组织所驻那座**算 */
export function addPersonRaw(name) {
  S.seq.p += 1;
  S.people.push({ id: "p" + String(S.seq.p).padStart(2, "0"), name, org: "" });
}
/* 组织所驻建筑实例是否装了某软装（未驻任何建筑＝不通过） */
export function orgEquip(o, item) {
  return !!(o && o.bldg && S.buildings[o.bldg.b]?.[o.bldg.idx]?.interior[item]);
}
export function addOrgRaw(name, tier, kind) {
  S.seq.o += 1;
  const id = "o" + String(S.seq.o).padStart(2, "0");
  const tpl = ORGS[name] || {};
  const org = { id, name, tier, kind: kind || "", template: name, slots: {}, steps: tpl.steps || [],
                bldgType: tpl.bldg || "", bldg: null, settings: {} };
  for (const opt of (ORG_PANELS[name] || [])) org.settings[opt.key] = opt.choices[0][0];
  S.orgs[id] = org;
  if (kind !== "hall")
    for (const def of (tpl.slots || []))
      org.slots[def.fn] = { def, persons: [], institution: "", product: "" };
  if (org.bldgType) {   // 自动进驻一座空置同类建筑；没有则空挂（基础运转受限，工厂工序全停摆）
    const idx = (S.buildings[org.bldgType] || []).findIndex(inst => !inst.org);
    if (idx >= 0) { S.buildings[org.bldgType][idx].org = id; org.bldg = { b: org.bldgType, idx }; }
  }
  S.order.push(id);
  return org;
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
  // 动员产率：耕战（无军或动员兵役）集结减半；常备兵役的职业兵打仗、生产照转
  let mult = 1;
  if (S.mobilized) {
    const army = Object.values(S.orgs).find(x => x.template === "常备军");
    mult = army && army.settings["兵役制度"] === "常备兵役" ? 1 : 0.5;
  }
  const flow = {}; for (const r of RES) flow[r] = 0;
  S.borrows = {};
  // ① 信息通报与借调（先于采集：被借调者本拍离岗）
  const notified = {};
  const awayFrom = {};
  for (const o of Object.values(S.orgs)) {
    const workSlots = Object.values(o.slots).filter(s => s.def.terrain);
    if (!workSlots.length) continue;
    const infoSlots = Object.values(o.slots).filter(s => /信息/.test(s.def.fn));
    // 额外椅子（软装）：联络更快——更早进入通报阈值
    const notifyLine = K.buf * (orgEquip(o, "额外椅子") ? 0.15 : 0.3);
    for (const ws of workSlots) {
      const key = bufKey(ws.def.terrain, slotProduct(ws));
      const needNotify = S.buf[key] > notifyLine;
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
      if (d.terrain === "树林" && orgEquip(o, "工具架")) rate *= 1.25;
      const amt = rate * w * mult * dt;
      const key = bufKey(d.terrain, slotProduct(slot));
      const room = K.buf - S.buf[key];
      const got = Math.min(amt, Math.max(0, room));
      S.buf[key] += got; flow[slotProduct(slot)] += got;
    }
  }
  // ②′ 生产部·采集兜底：无专门队时的泛采集（0.4/人时，均摊到仍有余量的缓冲堆）
  const dept = Object.values(S.orgs).find(x => x.template === "生产局");
  const deptGatherers = dept ? (dept.slots["采集"]?.persons.length || 0) : 0;
  if (deptGatherers) {
    const amt = K.deptGather * deptGatherers * mult * dt;
    const roomKeys = Object.keys(S.buf).filter(k => S.buf[k] < K.buf - 0.001);
    if (roomKeys.length) {
      const part = amt / roomKeys.length;
      for (const k of roomKeys) {
        const got = Math.min(part, K.buf - S.buf[k]);
        S.buf[k] += got; flow[k.split("|")[1]] += got;
      }
    }
  }
  // ③ 搬运（库管在岗才运转；被通报场地全速，未通报打折扣）
  let haulers = 0, keeper = false;
  for (const o of Object.values(S.orgs)) {
    const kp = o.slots["库管"]; if (kp && kp.persons.length) keeper = true;
    const hp = o.slots["搬运"]; if (hp) haulers += hp.persons.length;
  }
  if (keeper && haulers > 0) {
    // 调度（运输队·运输计划与派单）在岗：未通报场地的搬运折扣减轻
    let dispatcher = false;
    for (const o of Object.values(S.orgs)) { const s = o.slots["调度"]; if (s && s.persons.length) dispatcher = true; }
    let haulRate = K.haul;
    for (const o of Object.values(S.orgs))
      if (o.slots["搬运"] && o.settings["载具"] === "手推车") haulRate = K.haul * 1.5;
    const cap = haulRate * haulers * mult * dt;
    const keys = Object.keys(S.buf).filter(key2 => S.buf[key2] > 0.001);
    const totalBuf = keys.reduce((a, key2) => a + S.buf[key2], 0);
    const move = Math.min(cap, totalBuf, Math.max(0, capTotal() - resTotal()));
    if (move > 0) for (const key2 of keys) {
      const part = S.buf[key2] / totalBuf;
      const disc = notified[key2] === false ? (dispatcher ? 0.7 : K.uninfo) : 1;
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
      if (!orgEquip(o, st.equip)) return false;
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
        const ingotFirst = o.settings["锻打原料"] === "铁锭优先" && st.altCity;
        let inner = 0, outer = 0;
        if (ingotFirst) {   // 外购优先：先吃铁锭，不够再吃厂内半成品
          const canOut = Math.min(want, ...Object.entries(st.altCity).map(([r, n]) => S.res[r] / n));
          if (canOut > 0) { for (const [r, n] of Object.entries(st.altCity)) { S.res[r] -= n * canOut; flow[r] -= n * canOut; }
            outer = canOut; }
          inner = Math.min(want - outer, wipOf(o)[st.wipIn] || 0);
          wipOf(o)[st.wipIn] -= inner;
        } else {
          inner = Math.min(want, wipOf(o)[st.wipIn] || 0);
          wipOf(o)[st.wipIn] -= inner;
          if (st.altCity) {
            const canOut = Math.min(want - inner, ...Object.entries(st.altCity).map(([r, n]) => S.res[r] / n));
            if (canOut > 0) { for (const [r, n] of Object.entries(st.altCity)) { S.res[r] -= n * canOut; flow[r] -= n * canOut; }
              outer = canOut; }
          }
        }
        produced = inner + outer;
      }
      if (produced > 0) {
        if (st.wip) wipOf(o)[st.wip] = (wipOf(o)[st.wip] || 0) + produced;
        else if (st.outCity) for (const [r, n] of Object.entries(st.outCity)) { S.res[r] += n * produced; flow[r] += n * produced; }
      }
    }
  }
  // ⑤ 施工队列（测量在岗=放线准少返工，施工效率×1.15）
  if (S.buildOrders.length) {
    let w = 0, survey = false;
    for (const o of Object.values(S.orgs)) {
      const s = o.slots["施工"]; if (s) w += s.persons.length;
      const m = o.slots["测量"]; if (m && m.persons.length) survey = true;
    }
    if (w) {
      const ord = S.buildOrders[0];
      ord.done += w * (survey ? 1.15 : 1) * mult * dt;
      if (ord.done >= ord.work) {
        if (ord.kind === "shell") {
          S.buildings[ord.b].push({ interior: {}, org: "" });
          const idx = S.buildings[ord.b].length - 1;
          const waitOrg = Object.values(S.orgs).find(x => x.bldgType === ord.b && !x.bldg);
          if (waitOrg) {   // 组建在建筑之前的空挂组织，落成即自动进驻
            S.buildings[ord.b][idx].org = waitOrg.id;
            waitOrg.bldg = { b: ord.b, idx };
            feed(`${waitOrg.name} 进驻新落成的${ord.b}${CIRC[idx]}`, "good");
          }
        }
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
/* 构筑＝选中空槽位后从候选中建子组织（子机构可不断递归）；放一个人顶岗走 putPerson */
export function createOrgAt(containerId, fn, name) {
  const container = S.orgs[containerId];
  if (!container || !container.slots[fn]) return;
  const slot = container.slots[fn];
  if (slot.institution || slot.persons.length) { feed(`${container.name}「${fn}」槽已被占用`, "bad"); return; }
  const cost = LATE_COST[name] || {};
  if (cost.prereq) { feed(`「${name}」明面前提未满足：${cost.prereq}`, "bad"); return; }
  if (cost.res && !canPay(cost.res)) { feed(`构筑「${name}」资源不足（${costStr(cost.res)}）`, "bad"); return; }
  if (cost.res) pay(cost.res);
  const o = addOrgRaw(name, 2, "");
  slot.institution = o.id;
  feed(`构筑 ${o.name}，入驻 ${container.name}「${fn}」槽`, "good");
  if (o.bldgType)
    feed(o.bldg
      ? `${o.name} 驻${o.bldg.b}${CIRC[o.bldg.idx]}`
      : `${o.name} 无${o.bldgType}可驻——基础运转受限，先再建一座`, o.bldg ? "good" : "bad");
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
  if (o.bldg && S.buildings[o.bldg.b]?.[o.bldg.idx]) S.buildings[o.bldg.b][o.bldg.idx].org = "";   // 退出所驻建筑
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
