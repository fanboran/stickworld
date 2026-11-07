import { reactive } from "vue";

/* ═════════ 自然地形（城市自带；采集需要对应地形在场）——本城树林/矿洞/农田都有 ═════════ */
export const TERRAIN = {
  "树林": { products: ["原木"] },
  "矿洞": { products: ["铁矿"] },
  "农田": { products: ["农作物"] },   // 农作物：战粮原料兼入药原料，单产物
};
/* 城市库存品目录（可进仓库）。cat：basic=基础原料 / mat=材料 / prod=制品（顶栏只放 basic，全量在仓库页）。
   原料窄口径（05-经济系统 §四）：基础原料三种——原木/矿物（暂只做铁）/农作物，全部地形直出；
   木材/木板/铁锭都是工序产物（加工品），多样性靠工序不靠原料。
   进食是可选增益、不设「食物」资源；铁水/毛坯/淬火件/净药材/车料是厂内物品，不可离厂（仓库页「厂内」标签可见） */
export const RES = ["原木", "铁矿", "农作物", "木材", "木板", "铁锭", "铁剑", "药水", "手推车"];
export const RES_INFO = {
  "原木":   { cat: "basic", icon: "🌲", src: "伐木队采自树林——锯木坊锯解的原料" },
  "铁矿":   { cat: "basic", icon: "🪨", src: "矿物·暂只做铁——采矿队采自矿洞" },
  "农作物": { cat: "basic", icon: "🌾", src: "农田产出——战粮类增益品原料（进食可选增益、无饥饿），亦可炮制入药" },
  "木材":   { cat: "mat", icon: "🪵", src: "锯木坊锯解原木所得（建材/工具/载具用料）" },
  "木板":   { cat: "mat", icon: "🟫", src: "锯木坊刨光木材所得" },
  "铁锭":   { cat: "mat", icon: "🔩", src: "冶炼坊自产（或初始库存）" },
  "铁剑":   { cat: "prod", icon: "🗡️", src: "锻造坊开刃出品——成军军械储备" },
  "药水":   { cat: "prod", icon: "🧪", src: "药剂坊熬制" },
  "手推车": { cat: "prod", icon: "🛒", src: "木器坊装配——运输队载具（运力 1.8/人时）" },
};
export const RES_CATS = [["basic", "基础原料"], ["mat", "材料"], ["prod", "制品"]];
export const BASIC_RES = RES.filter(r => RES_INFO[r].cat === "basic");

/* ═════════ 建筑（与组织独立：组织无建筑可基础运转；建筑解锁进阶槽位与设备工序） ═════════ */
export const BUILDINGS = {
  "市政厅": { prebuilt: true, desc: "城市根组织所在" },
  "仓库":   { prebuilt: true, desc: "资源与制品的集中存放；每座+容量、搬运坑位随座数增长",
    shell: { cost: { "木材": 20 }, work: 20 } },
  "伐木小屋": { desc: "伐木队办公与工具场所（无它也能伐：探测/记录被禁）",
    shell: { cost: { "木材": 20 }, work: 20 }, interior: [
      { item: "办公桌椅", cost: { "木材": 6 }, work: 6, unlock: "解锁伐木队的探测/记录槽" },
      { item: "工具架",   cost: { "木板": 4 }, work: 6, effect: "伐木速率+25%" },
      { item: "额外椅子", cost: { "木板": 2 }, work: 3, effect: "木材信息联络更快" } ] },
  "锯木坊": { desc: "锯解→刨光：原木出木材，木材再出木板",
    shell: { cost: { "木材": 15 }, work: 16 }, interior: [
      { item: "锯架", cost: { "木材": 8 }, work: 8, unlock: "锯解工序（原木→木材）" },
      { item: "刨台", cost: { "木板": 2 }, work: 5, unlock: "刨光工序（木材→木板）" } ] },
  "锻造坊": { desc: "熔炼→锻打→淬火→开刃，出铁剑（半成品不出厂）",
    shell: { cost: { "木材": 25 }, work: 24 }, interior: [
      { item: "熔炉", cost: { "木材": 10, "木板": 4 }, work: 10, unlock: "熔炼工序（铁矿+木材→铁水）" },
      { item: "铁砧", cost: { "铁矿": 4 }, work: 8, unlock: "锻打工序（铁水/铁锭→毛坯）" },
      { item: "水槽", cost: { "木材": 6 }, work: 5, unlock: "淬火工序（毛坯→淬火件）" },
      { item: "磨石", cost: { "铁矿": 2 }, work: 5, unlock: "开刃工序（淬火件→铁剑）" },
      { item: "风箱", cost: { "木材": 4, "铁矿": 1 }, work: 4, unlock: "风箱岗：拉风箱助熔，熔炼提速（鼓风提炉温）" } ] },
  "药剂坊": { desc: "农作物 → 净药材 → 药水",
    shell: { cost: { "木材": 12 }, work: 12 }, interior: [
      { item: "切药刀", cost: { "铁矿": 1 }, work: 4, unlock: "炮制工序（农作物→净药材）" },
      { item: "药炉",   cost: { "木材": 8 }, work: 6, unlock: "熬制工序（净药材→药水）" } ] },
  "训练场": { desc: "教官与受训编制的演武场",
    shell: { cost: { "木材": 18 }, work: 18 }, interior: [
      { item: "木人桩", cost: { "木材": 6 }, work: 6, unlock: "解锁教官岗" },
      { item: "靶场",   cost: { "木板": 4 }, work: 5, effect: "演武器材（机制后续）" } ] },
  "兵营": { desc: "常备军的营房",
    shell: { cost: { "木材": 20 }, work: 20 }, interior: [] },
  "官署": { desc: "人事与组织的衙署",
    shell: { cost: { "木材": 14 }, work: 14 }, interior: [
      { item: "案牍", cost: { "木材": 5 }, work: 5, unlock: "解锁人事岗" } ] },
  "书院": { desc: "研究者的书斋与实验间",
    shell: { cost: { "木材": 16, "木板": 6 }, work: 18 }, interior: [
      { item: "书架",   cost: { "木板": 4 }, work: 5, unlock: "解锁课题管理岗" },
      { item: "实验台", cost: { "铁矿": 2 }, work: 6, unlock: "解锁实验岗" } ] },
  "民居": { desc: "村民居住位（基准4位，装床铺翻倍——能住几人由床位决定）；有空位且温饱，人口缓增",
    shell: { cost: { "木材": 12 }, work: 12 }, interior: [
      { item: "床铺", cost: { "木材": 4 }, work: 4, effect: "居住位+2" } ] },
  "木工房": { desc: "备料→装配，出手推车（车料为厂内物品）",
    shell: { cost: { "木材": 15, "铁矿": 2 }, work: 16 }, interior: [
      { item: "木工台", cost: { "木材": 8, "铁矿": 2 }, work: 8, unlock: "备料工序（木板+铁锭→车料）" },
      { item: "组装架", cost: { "木材": 6 }, work: 5, unlock: "装配工序（车料→手推车）" } ] },
  "冶炼坊": { late: true, desc: "矿石入炉炼铁，出铁锭（后期）",
    shell: { cost: { "木材": 25 }, work: 24 }, interior: [
      { item: "冶炼炉", cost: { "铁矿": 6, "木板": 4 }, work: 12, unlock: "冶炼工序（铁矿+木材→铁锭，柴火熔炉）" } ] },
};

/* ═════════ 组织模板。host＝可入驻的槽名（选中空槽即弹出该槽可构筑的子组织，可递归）；
   pos＝岗位用人类型（标签色）：must=必须（至少一人该组织才能开工，人数可弹性）
   · semi=半必须（需人运行但不必时刻有人，可从本队别岗移调）
   · gain=增益（无人也行，只是未解锁/缺失该功能——解锁类）；
   role＝「放人/放组织解锁什么」的能力标注；bldg＝需进驻的建筑类型（03 §一）═════════ */
export const ORGS = {
  "生产局": { host: "生产", slots: [
      { fn: "采集", n: 1, pos: "gain", role: "放人泛采集（0.4/人时），放采集中心统筹三线" },
      { fn: "建造", n: 1, pos: "gain", role: "放人督造，放工程队成建制施工" },
      { fn: "制造", n: 1, pos: "gain", role: "放人跟单，放制造中心统筹各坊" } ] },
  "采集中心": { host: "采集", slots: [
      { fn: "伐木", n: 1, pos: "gain", role: "原木产出线" },
      { fn: "采矿", n: 1, pos: "gain", role: "铁矿产出线" },
      { fn: "农垦", n: 1, pos: "gain", role: "农作物产出线" } ] },
  "制造中心": { host: "制造", slots: [
      { fn: "锯木", n: 1, pos: "gain", role: "原木→木材→木板" },
      { fn: "锻造", n: 1, pos: "gain", role: "铁矿→铁剑" },
      { fn: "制药", n: 1, pos: "gain", role: "农作物→药水" },
      { fn: "木器", n: 1, pos: "gain", role: "木板+铁锭→手推车（载具）" },
      { fn: "冶炼", n: 1, pos: "gain", role: "铁矿→铁锭（后期）" } ] },
  "工程队": { host: "建造", slots: [
      { fn: "测量", n: 1, pos: "gain", role: "放线与验收" },
      { fn: "施工", n: 4, homog: true, pos: "must", role: "硬装软装都干" },
      { fn: "质检", n: 1, pos: "gain", role: "工序与落成核验" } ] },
  "运输队": { host: "运输", slots: [
      { fn: "调度", n: 1, pos: "gain", role: "减轻未通报场地的搬运损耗" },
      { fn: "库管", n: 1, pos: "must", role: "在岗搬运才运转" },
      { fn: "搬运", n: 5, homog: true, pos: "must", role: "负责搬运" } ] },
  "伐木队": { host: "伐木", bldg: "伐木小屋", slots: [
      { fn: "伐木", n: 4, homog: true, pos: "must", terrain: "树林", role: "负责伐木" },
      { fn: "木材信息", n: 1, pos: "semi", role: "收集木材线信息呈递给你" },
      { fn: "探测", n: 1, pos: "gain", req: { b: "伐木小屋", item: "办公桌椅" }, role: "收集林木资源情报呈递给你" },
      { fn: "记录", n: 1, pos: "gain", req: { b: "伐木小屋", item: "办公桌椅" }, role: "记录木材出入并呈递给你" } ] },
  "采矿队": { host: "采矿", slots: [
      { fn: "挖矿", n: 4, homog: true, pos: "must", terrain: "矿洞", role: "负责挖矿" },
      { fn: "支护", n: 1, pos: "gain", role: "架坑木支撑坑道" },
      { fn: "提升", n: 1, pos: "gain", role: "坑口吊运，矿石出坑装堆" },
      { fn: "矿石信息", n: 1, pos: "semi", role: "收集矿石线信息呈递给你" } ] },
  "农垦队": { host: "农垦", slots: [
      { fn: "耕作", n: 4, homog: true, pos: "must", terrain: "农田", role: "负责耕作" },
      { fn: "选种", n: 1, pos: "gain", role: "留优种作来年种籽" },
      { fn: "农情信息", n: 1, pos: "semi", role: "收集农情信息呈递给你" } ] },
  "锯木坊": { host: "锯木", bldg: "锯木坊", slots: [
      { fn: "锯解", n: 1, pos: "semi", step: 0, role: "原木开成木材" },
      { fn: "刨光", n: 1, pos: "semi", step: 1, role: "木材刨成木板" } ],
      steps: [ { name: "锯解", equip: "锯架", inCity: { "原木": 1 }, outCity: { "木材": 1 } },
               { name: "刨光", equip: "刨台", inCity: { "木材": 1 }, outCity: { "木板": 1 } } ] },
  "锻造坊": { host: "锻造", bldg: "锻造坊", slots: [
      { fn: "风箱", n: 1, pos: "semi", role: "拉风箱助熔——鼓风提炉温" },
      { fn: "熔炼", n: 1, pos: "semi", step: 0, role: "铁矿+木材化铁水" },
      { fn: "锻打", n: 1, pos: "semi", step: 1, role: "铁水或铁锭锻毛坯" },
      { fn: "淬火", n: 1, pos: "semi", step: 2, role: "毛坯淬火" },
      { fn: "开刃", n: 1, pos: "semi", step: 3, role: "淬火件开刃成剑" } ],
      steps: [   // 古代冶炼/锻造分工；半成品为厂内物品不可离厂；锻打原料偏好见组织面板
        { name: "熔炼", equip: "熔炉", inCity: { "铁矿": 1, "木材": 1 }, wip: "铁水" },
        { name: "锻打", equip: "铁砧", wipIn: "铁水", altCity: { "铁锭": 1 }, wip: "毛坯" },
        { name: "淬火", equip: "水槽", wipIn: "毛坯", wip: "淬火件" },
        { name: "开刃", equip: "磨石", wipIn: "淬火件", outCity: { "铁剑": 1 } } ] },
  "药剂坊": { host: "制药", bldg: "药剂坊", slots: [
      { fn: "炮制", n: 1, pos: "semi", step: 0, role: "农作物炮制净药材" },
      { fn: "熬制", n: 1, pos: "semi", step: 1, role: "净药材熬成药水" } ],
      steps: [
        { name: "炮制", equip: "切药刀", inCity: { "农作物": 1 }, wip: "净药材" },
        { name: "熬制", equip: "药炉", wipIn: "净药材", outCity: { "药水": 1 } } ] },
  "木器坊": { host: "木器", bldg: "木工房", slots: [
      { fn: "备料", n: 1, pos: "semi", step: 0, role: "木板铁锭备成车料" },
      { fn: "装配", n: 1, pos: "semi", step: 1, role: "车料装成手推车" } ],
      steps: [
        { name: "备料", equip: "木工台", inCity: { "木板": 2, "铁锭": 1 }, wip: "车料" },
        { name: "装配", equip: "组装架", wipIn: "车料", outCity: { "手推车": 1 } } ] },
  /* 职能槽下辖的专门组织（任意槽可下辖；信息/库管槽内的精细化示例，可继续递归） */
  "林务所": { host: "木材信息", slots: [
      { fn: "巡看", n: 2, homog: true, pos: "must", role: "巡看林中堆存与路况" },
      { fn: "记档", n: 1, pos: "gain", role: "汇总木材台账" } ] },
  "矿务所": { host: "矿石信息", slots: [
      { fn: "巡看", n: 2, homog: true, pos: "must", role: "巡看矿场堆存" },
      { fn: "记档", n: 1, pos: "gain", role: "汇总矿石台账" } ] },
  "农务所": { host: "农情信息", slots: [
      { fn: "巡看", n: 2, homog: true, pos: "must", role: "巡看田场堆存" },
      { fn: "记档", n: 1, pos: "gain", role: "汇总农情台账" } ] },
  "库务所": { host: "库管", slots: [
      { fn: "收发", n: 1, pos: "must", role: "出入库过秤记账" },
      { fn: "盘点", n: 1, pos: "gain", role: "清点库房核对账实" } ] },
  "人事局": { host: "行政", bldg: "官署", slots: [
      { fn: "人事", n: 1, pos: "must", req: { b: "官署", item: "案牍" }, role: "自动补员：待业者补进缺员的必须岗（在编越多补得越勤）" },
      { fn: "组织管理", n: 1, pos: "gain", role: "组织编制管理（后期：自适应扩建与改编）" } ] },
  "情报局": { host: "情报", slots: [
      { fn: "汇总", n: 1, pos: "must", role: "汇总各线呈递，生成一站式总览" },
      { fn: "采编", n: 2, homog: true, pos: "must", role: "到各信息岗采编一线情报" },
      { fn: "抄送", n: 1, pos: "gain", role: "把总览分发到各指令面板" } ] },
  /* 后期 */
  "冶炼坊": { host: "冶炼", bldg: "冶炼坊",
      slots: [ { fn: "冶炼", n: 1, pos: "semi", step: 0, role: "铁矿配柴入炉炼锭" } ],
      steps: [ { name: "冶炼", equip: "冶炼炉", inCity: { "铁矿": 1, "木材": 1 }, outCity: { "铁锭": 1 } } ] },
  "常备军": { host: "军事", bldg: "兵营", late: true, slots: [
      { fn: "军事", n: 1, pos: "must", role: "在编即可动员" },
      { fn: "军需", n: 1, pos: "gain", role: "战粮军械领用配发登记" },
      { fn: "训练", n: 1, pos: "gain", role: "放训练营成建制施训" } ] },
  "训练营": { host: "训练", bldg: "训练场", late: true, slots: [
      { fn: "训练管理", n: 1, pos: "gain", role: "排训练计划" },
      { fn: "教官", n: 4, homog: true, pos: "must", req: { b: "训练场", item: "木人桩" }, role: "施训教官" },
      { fn: "器材管理", n: 1, pos: "gain", role: "维护训练器材" } ] },
  "科研院": { host: "科研", bldg: "书院", late: true, slots: [
      { fn: "课题管理", n: 1, pos: "gain", req: { b: "书院", item: "书架" }, role: "选题与立项" },
      { fn: "实验", n: 3, homog: true, pos: "must", req: { b: "书院", item: "实验台" }, role: "产出新技能，长在本人身上" },
      { fn: "文献记录", n: 1, pos: "gain", role: "汇总技能台账并呈递给你" } ] },
};
export const HALL_SLOT_KEYS = ["市长", "军事", "行政", "生产", "运输", "科研", "情报"];
/* 成军＝军械储备（铁剑×2 入库）+ 集结口粮（农作物×50）——制品与原料的实物资费 */
export const LATE_COST = { "常备军": { res: { "农作物": 50, "铁剑": 2 } }, "训练营": { res: { "木材": 15 } },
                           "科研院": { res: { "木板": 10 }, prereq: "在编有人会占位组织技能（技能机制未实装）" } };
/* 空槽的可构筑候选（按槽名匹配 host——组织树即构筑树；别名＝放弃统筹层直挂单线的路径偏好） */
export const SLOT_ALIAS = { "采集": ["伐木队", "采矿队", "农垦队"], "制造": ["锯木坊", "锻造坊", "药剂坊", "木器坊"] };
export const slotCandidates = fn => {
  const base = Object.entries(ORGS).filter(([, t]) => t.host === fn).map(([n]) => n);
  return [...base, ...(SLOT_ALIAS[fn] || []).filter(n => !base.includes(n))];
};
/* 递归允许专门化，但同型自嵌套（伐木队槽里再放伐木队）无意义——由调用侧按宿主模板排除 */
/* 组织控制面板选项（实际游戏为各组织专属的复杂精美 UI，sim 只模拟基础功能；
   选不同机构＝功能实现路径的偏好，如同计划 or 市场） */
export const ORG_PANELS = {
  "常备军": [ { key: "兵役制度", choices: [["动员兵役", "耕战一体：战时集结，动员时产率减半"],
                                            ["常备兵役", "职业兵维持需后勤供给（后续），动员不减产率"]] } ],
  "工程队": [ { key: "自动扩建", choices: [["关", "全部施工手动排队"],
                                          ["开", "仓库近满且无在办建造单时，自动排队再建一座（保底不压主线）"]] } ],
  "运输队": [ { key: "载具", choices: [["人力搬运", "1.2/人时"],
                                        ["手推车", "1.8/人时——库中需有车（木器坊出品）", { need: "手推车" }]] },
              { key: "装卸规则", choices: [["均匀分运", "各场地按堆量比例搬运"],
                                            ["大宗优先", "先清最大堆——场地少顶格停采，小堆排后"]] } ],
  "锯木坊": [ { key: "出材偏好", choices: [["优先木材", "锯解多出力：木材供燃料与建材"],
                                          ["优先木板", "刨光多出力：木板供下游制造"]] } ],
  "锻造坊": [ { key: "锻打原料", choices: [["铁水优先", "以厂内自炼铁水为主"],
                                            ["铁锭优先", "以库存铁锭为主，省下燃料"]] } ],
  "科研院": [ { key: "选题", choices: [["实用优先", "先解当前生产急用（机制后续）"],
                                        ["底层探究", "先钻基础原理（机制后续）"]] } ],
};
/* 建不了的原因（拒止反馈落在按钮态上）：前提→资源，与构筑同序 */
export function createBlocked(name) {
  const t = ORGS[name];
  if (t?.bldg && !(S.buildings[t.bldg] || []).some(i => !i.org))
    return `需先再建一座${t.bldg}（该类组织必须依附建筑）`;
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
  sel: null, selSlot: null, feed: [], rates: {}, snap: null,
  cityL: [], cityR: [], autoCd: 0, popCd: 0,
  knobs: { gather: 0.8, deptGather: 0.4, haul: 1.2, craft: 0.6, uninfo: 0.5, buf: 40, cap: 400 },
});

/* 聚落开局：根组织叫「聚落」（人口达 30 升格更名市政厅）；自带市政厅与仓库各一座，
   一切组织与建筑从零搭起。完全体展示样板见 loadDemo()（参数面板可载入） */
export function reset() {
  const fresh = {
    hours: 0, speed: 0, seq: { p: 0, o: 0 },
    people: [], orgs: {}, order: [],
    res: { "原木": 30, "铁矿": 0, "农作物": 30, "木材": 40, "木板": 4, "铁锭": 0, "铁剑": 0, "药水": 0, "手推车": 0 },
    // 木材 40＝自举本金：锯木坊壳15+锯架8 是最小开工单元，再留 民居12+床4 的首屋余量——低于此开局锁死（无木材产能）
    buf: {}, wip: {}, buildings: {}, buildOrders: [],
    mobilized: false, borrows: {},
    sel: null, selSlot: null, feed: [], rates: {}, snap: null,
    cityL: [], cityR: [], autoCd: 0, popCd: 0,
  };
  Object.assign(S, fresh);
  for (const b of Object.keys(BUILDINGS))
    S.buildings[b] = BUILDINGS[b].prebuilt ? [{ interior: {}, org: "" }] : [];
  S.cityR.push({ b: "仓库", inst: 0 });   // 市政厅居中，仓库落在右侧首块
  for (const [site, t] of Object.entries(TERRAIN))
    for (const p of t.products) S.buf[site + "|" + p] = 0;
  const hall = addOrgRaw("市政厅", 1, "hall");
  hall.name = "聚落";
  for (const key of HALL_SLOT_KEYS)
    hall.slots[key] = { def: { fn: key, n: 1, pos: key === "市长" ? "must" : "gain",
      role: { "市长": "统辖聚落（你）", "军事": "掌军，在编即可动员", "行政": "管理人事与组织",
              "生产": "辖采集/建造/制造三线", "运输": "启用物流系统", "科研": "主持研究",
              "情报": "生成一站式信息总览" }[key] },
      persons: [], institution: "", product: "" };
  addPersonRaw("你"); hall.slots["市长"].persons = ["p01"]; S.people[0].org = hall.id;
  addPersonRaw("动员官"); hall.slots["军事"].persons = ["p02"]; S.people[1].org = hall.id;
  for (let i = 0; i < 8; i++) addPersonRaw("村民");
  feed("聚落开局：根组织「聚落」+市政厅/仓库各一座。选空槽派人或构筑组织，从零搭起一切");
  S.snap = collectSnap();
}

/* 完全体样板（原默认展示）：参数面板「载入完全体」可一键载入 */
export function loadDemo() {
  reset();
  const inst = (b, ...items) => {
    const it = {}; for (const x of items) it[x] = true;
    S.buildings[b].push({ interior: it, org: "" });
    S.cityR.push({ b, inst: S.buildings[b].length - 1 });
  };
  inst("伐木小屋", "办公桌椅", "工具架", "额外椅子");
  inst("锯木坊", "锯架", "刨台");
  inst("锻造坊", "熔炉", "铁砧", "水槽", "磨石", "风箱");
  inst("冶炼坊", "冶炼炉");
  for (let i = 0; i < 6; i++) inst("民居", "床铺");
  inst("训练场", "木人桩", "靶场");
  inst("兵营"); inst("官署", "案牍"); inst("书院", "书架", "实验台");
  inst("药剂坊", "切药刀", "药炉");
  inst("木工房", "木工台", "组装架");
  addPersonRaw("你");
  addPersonRaw("动员官");
  for (let i = 0; i < 34; i++) addPersonRaw("村民");
  const hall = addOrgRaw("市政厅", 3, "hall");
  for (const key of HALL_SLOT_KEYS)
    hall.slots[key] = { def: { fn: key, n: 1, pos: key === "市长" ? "must" : "gain",
      role: { "市长": "统辖全城（你）", "军事": "掌军，在编即可动员", "行政": "管理人事与组织",
              "生产": "辖采集/建造/制造三线",
              "运输": "启用物流系统", "科研": "主持研究", "情报": "生成一站式信息总览" }[key] },
      persons: [], institution: "" };
  const vill = () => S.people.filter(p => !p.org).map(p => p.id);
  const place = (container, fn, org) => { container.slots[fn].institution = org.id; };
  const staff = (org, fn, n, ids) => {
    for (const pid of ids.slice(0, n)) { org.slots[fn].persons.push(pid); person(pid).org = org.id; }
  };
  /* 组织树：市政厅 → 生产局（采集中心→伐木/采矿/农垦 · 工程队 · 制造中心→锯木/锻造/药剂/木器）· 运输队（库管=库务所入驻）· 常备军（训练=训练营）· 科研院 */
  hall.slots["市长"].persons = ["p01"]; S.people[0].org = hall.id;
  const dept = addOrgRaw("生产局", 2, ""); place(hall, "生产", dept);
  const gather = addOrgRaw("采集中心", 2, ""); place(dept, "采集", gather);
  const works = addOrgRaw("制造中心", 2, ""); place(dept, "制造", works);
  const eng = addOrgRaw("工程队", 2, ""); place(dept, "建造", eng);
  const lumber = addOrgRaw("伐木队", 2, ""); place(gather, "伐木", lumber);
  const mining = addOrgRaw("采矿队", 2, ""); place(gather, "采矿", mining);
  const farm = addOrgRaw("农垦队", 2, ""); place(gather, "农垦", farm);
  const sawmill = addOrgRaw("锯木坊", 2, ""); place(works, "锯木", sawmill);
  const forge = addOrgRaw("锻造坊", 2, ""); place(works, "锻造", forge);
  const pharmacy = addOrgRaw("药剂坊", 2, ""); place(works, "制药", pharmacy);
  const smelter = addOrgRaw("冶炼坊", 2, ""); place(works, "冶炼", smelter);
  const cartshop = addOrgRaw("木器坊", 2, ""); place(works, "木器", cartshop);
  const haul = addOrgRaw("运输队", 2, ""); place(hall, "运输", haul);
  const store = addOrgRaw("库务所", 2, ""); place(haul, "库管", store);   // 机构入驻库管槽＝库管履职
  const army = addOrgRaw("常备军", 2, ""); place(hall, "军事", army);
  army.slots["军事"].persons = ["p02"]; S.people[1].org = army.id;
  const camp = addOrgRaw("训练营", 2, ""); place(army, "训练", camp);
  const sci = addOrgRaw("科研院", 2, ""); place(hall, "科研", sci);
  const intel = addOrgRaw("情报局", 2, ""); place(hall, "情报", intel);
  const hr = addOrgRaw("人事局", 2, ""); place(hall, "行政", hr);
  /* 满员运转 */
  let q = vill();
  staff(lumber, "伐木", 2, q); staff(mining, "挖矿", 2, q.slice(2));
  staff(farm, "耕作", 2, q.slice(4));
  staff(haul, "调度", 1, q.slice(6)); staff(store, "收发", 1, q.slice(7)); staff(haul, "搬运", 3, q.slice(8));
  staff(eng, "测量", 1, q.slice(11)); staff(eng, "施工", 2, q.slice(12));
  staff(forge, "风箱", 1, q.slice(14)); staff(forge, "熔炼", 1, q.slice(15)); staff(forge, "锻打", 1, q.slice(16));
  staff(forge, "淬火", 1, q.slice(17)); staff(forge, "开刃", 1, q.slice(18));
  staff(sawmill, "锯解", 1, q.slice(19));
  staff(pharmacy, "炮制", 1, q.slice(20));
  staff(cartshop, "备料", 1, q.slice(25));   // 木器坊一人厂：备料在编，装配经移调语义照常开工（工时均摊）
  staff(smelter, "冶炼", 1, q.slice(24));
  staff(hr, "人事", 1, q.slice(26));
  staff(intel, "汇总", 1, q.slice(27)); staff(intel, "采编", 2, q.slice(28));
  staff(sci, "课题管理", 1, q.slice(30)); staff(sci, "实验", 2, q.slice(31)); staff(sci, "文献记录", 1, q.slice(33));
  hall.name = "市政厅";
  feed("已载入完全体样板（聚落→市政厅，全建筑满编运转）");
  S.snap = collectSnap();   // 开局总览快照（此后按情报链更新周期刷新）
}


/* ── 工具 ── */
export const CIRC = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"];   // 建筑实例枚举（区分座，非命名）
export const person = pid => S.people.find(p => p.id === pid);
export const idle = () => S.people.filter(p => !p.org);
/* 城市布局：一整排，市政厅居中，向左/右两侧扩建；每型建筑占格宽（ CITY_W） */
export const CITY_W = { "市政厅": 4, "仓库": 3, "民居": 2, "伐木小屋": 2, "锯木坊": 3, "锻造坊": 3,
  "药剂坊": 3, "木工房": 3, "冶炼坊": 3, "训练场": 3, "兵营": 3, "官署": 2, "书院": 3 };
export function cityCells() {   // 从左到右的格子内容：{b,inst} 或 null 空地
  const out = [];
  for (const e of [...S.cityL].reverse()) for (let i = 0; i < (CITY_W[e.b] || 2); i++) out.push(e);
  for (let i = 0; i < (CITY_W["市政厅"] || 4); i++) out.push({ b: "市政厅", inst: 0 });
  for (const e of S.cityR || []) for (let i = 0; i < (CITY_W[e.b] || 2); i++) out.push(e);
  return out;
}

/* 居住位：每座民居 6 位，每台床铺 +2 */
export function housingCap() {
  // 住房容量由床位决定（建筑总账 6.6 创始人口径）：基准 4 位，装床铺翻倍
  let n = 0;
  for (const inst of (S.buildings["民居"] || [])) n += 4 + (inst.interior["床铺"] ? 4 : 0);
  return n;
}
/* 仓库按座计：每座一份容量（首座开局自带） */
export const capTotal = () => S.knobs.cap * (S.buildings["仓库"]?.length || 1);
/* 一站式总览＝把各处文书运回市政厅的汇总快照：信息量不随情报规模 gate——各组织
   面板的数据由它们自己的信息位收集；情报组织规模只决定更新效率（文书要真的有人拿回来）。
   汇总在编才有总览更新；采编每人把周期缩短（12时基础，每+1人-3时，下限1时）；无人=停更 */
export function intelInterval() {
  const hall = S.orgs.o01;
  const slot = hall?.slots["情报"];
  if (!slot) return Infinity;
  const org = slot.institution ? S.orgs[slot.institution] : null;
  if (!org) return slot.persons.length ? 24 : Infinity;   // 有人顶岗=自己顺路捎，日更
  if (!org.slots["汇总"]?.persons.length) return Infinity;
  const ed = org.slots["采编"]?.persons.length || 0;
  return Math.max(1, 12 - 3 * ed);
}
function collectSnap() {
  const m = o => o ? membersOf(o) : 0;
  const g = t => m(Object.values(S.orgs).find(x => x.template === t));
  return {
    at: S.hours,
    res: { ...S.res }, rates: { ...S.rates }, buf: { ...S.buf },
    queue: S.buildOrders.map(o => ({ label: o.kind === "shell" ? o.b + "·新座" : o.b + "·" + o.item,
      pct: Math.round(100 * o.done / o.work) })),
    lines: { 伐木队: g("伐木队"), 采矿队: g("采矿队"), 农垦队: g("农垦队"),
             运输队: g("运输队"), 库务所: g("库务所"), 锯木坊: g("锯木坊"), 锻造坊: g("锻造坊"),
             药剂坊: g("药剂坊"), 木器坊: g("木器坊"), 冶炼坊: g("冶炼坊"),
             常备军: g("常备军"), 科研院: g("科研院"), 情报局: g("情报局") },
    feed: S.feed.slice(-40).map(f => ({ ...f })),
    popu: { total: S.people.length, idle: S.people.filter(x => !x.org).length },
  };
}
/* 坑位上限随建筑规模：搬运坑位＝5×仓库座数；其余槽用模板定值 */
export function slotCap(o, slot) {
  if (slot.def.fn === "搬运") return 5 * (S.buildings["仓库"]?.length || 1);
  return slot.def.n ?? 1;
}
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
                bldgType: tpl.bldg || "", bldg: null, settings: {},
                trainLv: 0, trainProg: 0 };   // 受训等级与内部进度（0~100 点，04 §三）
  for (const opt of (ORG_PANELS[name] || [])) org.settings[opt.key] = opt.choices[0][0];
  S.orgs[id] = org;
  if (kind !== "hall")
    for (const def of (tpl.slots || []))
      org.slots[def.fn] = { def, persons: [], institution: "" };
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
/* 地形槽产物：原料窄口径下各地形单产物，直取 */
export function slotProduct(slot) {
  return TERRAIN[slot.def.terrain].products[0];
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
  // ① 信息通报与移调（先于采集：被移调者本拍离岗）
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
      const staffed = infoSlots.find(s => s.persons.length ||
        (s.institution && S.orgs[s.institution] && membersOf(S.orgs[s.institution]) > 0));   // 下辖组织有在编即履职
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
  // ②′ 生产局·采集兜底：无专门队时的泛采集（0.4/人时，均摊到仍有余量的缓冲堆）
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
    const kp = o.slots["库管"];
    if (kp && (kp.persons.length || (kp.institution && S.orgs[kp.institution] && membersOf(S.orgs[kp.institution]) > 0))) keeper = true;
    const hp = o.slots["搬运"]; if (hp) haulers += hp.persons.length;
  }
  if (keeper && haulers > 0) {
    // 调度（运输队·运输计划与派单）为职能岗：排单与派车的机制后续
    let haulRate = K.haul, bulkFirst = false;
    for (const o of Object.values(S.orgs)) if (o.slots["搬运"]) {
      if (o.settings["载具"] === "手推车" && S.res["手推车"] >= 1) haulRate = K.haul * 1.5;   // 车在手边才提速（与面板门控同一物理事实）
      if (o.settings["装卸规则"] === "大宗优先") bulkFirst = true;
    }
    const cap = haulRate * haulers * mult * dt;
    const keys = Object.keys(S.buf).filter(key2 => S.buf[key2] > 0.001);
    const totalBuf = keys.reduce((a, key2) => a + S.buf[key2], 0);
    const move = Math.min(cap, totalBuf, Math.max(0, capTotal() - resTotal()));
    if (move > 0) {
      // 装卸规则（物理行为差异，非乘数）：均匀分运=按堆量比例；大宗优先=先清最大堆，场地少顶格停采
      const order = bulkFirst ? [...keys].sort((a, b) => S.buf[b] - S.buf[a]) : keys;
      let remaining = move;
      for (const key2 of order) {
        const disc = notified[key2] === false ? K.uninfo : 1;
        const m = bulkFirst ? Math.min(remaining, S.buf[key2]) * disc
                            : move * (S.buf[key2] / totalBuf) * disc;
        if (bulkFirst) remaining -= m;
        S.buf[key2] -= m;
        S.res[key2.split("|")[1]] += m;
      }
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
    // 工时分流：默认均摊；带出材偏好的厂按 2:1 加权（偏好工序多占人力）
    const pref = o.settings["出材偏好"];
    const wts = steps.map(st => {
      if (!pref) return 1;
      const main = pref === "优先木材" ? "锯解" : "刨光";
      return st.name === main ? 2 : 1;
    });
    const wSum = wts.reduce((a, b, i) => a + (runnable[i] ? b : 0), 0);
    const perStepOf = i => workers * wts[i] / wSum;
    for (let i = 0; i < steps.length; i++) {
      if (!runnable[i]) continue;
      const st = steps[i];
      const slot = o.slots[st.name];
      if (slot && !slot.persons.length) {
        const src = Object.values(o.slots).find(s => s.persons.length);
        if (src) (S.borrows[o.id] ||= []).push({ from: src.def.fn, to: st.name });
      }
      let want = K.craft * perStepOf(i) * mult * dt;   // 工时按偏好权重分流（无偏好=均摊）
      // 鼓风提炉温：风箱岗有人且所驻坊装了风箱——熔炼这道工序提速（物理因果，非抽象加成）
      if (st.name === "熔炼" && o.slots["风箱"]?.persons.length && orgEquip(o, "风箱")) want *= 1.2;
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
        if (ingotFirst) {   // 铁锭优先：先吃库存铁锭，不够再吃厂内半成品
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
  // ⑤ 施工队列（工时=在岗施工人数）
  if (S.buildOrders.length) {
    let w = 0;
    for (const o of Object.values(S.orgs)) { const s = o.slots["施工"]; if (s) w += s.persons.length; }
    if (w) {
      const ord = S.buildOrders[0];
      ord.done += w * mult * dt;
      if (ord.done >= ord.work) {
        if (ord.kind === "shell") {
          S.buildings[ord.b].push({ interior: {}, org: "" });
          const idx = S.buildings[ord.b].length - 1;
          // 落成入排：新座进入城市一排（建筑页渲染；单上 side 定翼，未带 side 的单落右翼）
          (ord.side === "左" ? S.cityL : S.cityR).push({ b: ord.b, inst: idx });
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
  // ⑥′ 自动化：人事局补员 + 工程队自动扩建 + 人口缓增（组织规模越大自动化越高）
  {
    const hr = Object.values(S.orgs).find(x => x.template === "人事局");
    const nHR = hr ? hr.slots["人事"].persons.length : 0;
    if (nHR > 0) {
      S.autoCd = (S.autoCd || 0) + dt;
      if (S.autoCd >= 8 / nHR) {   // 人事在编越多补得越勤
        S.autoCd = 0;
        const idleP = S.people.find(x => !x.org);
        if (idleP) {
          let target = null;
          for (const o of Object.values(S.orgs))
            for (const [fn, sl] of Object.entries(o.slots))
              if (sl.def.pos === "must" && !sl.institution && sl.persons.length < slotCap(o, sl)
                  && (!target || sl.persons.length < target.sl.persons.length))
                target = { o, sl, fn };
          if (target) {
            target.sl.persons.push(idleP.id); idleP.org = target.o.id;
            feed(`人事局补员：待业者补进 ${target.o.name}「${target.fn}」`, "good");
          }
        }
      }
    }
    const eng = Object.values(S.orgs).find(x => x.template === "工程队");
    if (eng && eng.settings["自动扩建"] === "开" && S.buildings["仓库"]?.length
        && resTotal() >= capTotal() * 0.9
        && !S.buildOrders.length                      // 任何建造单在队时都不自动扩（保底不压主线、一次一座）
        && canPay(BUILDINGS["仓库"].shell.cost)) {
      pay(BUILDINGS["仓库"].shell.cost);
      S.buildOrders.push({ kind: "shell", b: "仓库", item: "", idx: -1,
        work: BUILDINGS["仓库"].shell.work, done: 0 });
      feed("工程队自动扩建：仓库近满，新一座已排队", "good");
    }
    S.popCd = (S.popCd || 0) + dt;
    if (S.popCd >= 24) {
      S.popCd = 0;
      if (housingCap() > S.people.length && S.res["农作物"] >= 10) {
        S.res["农作物"] -= 10;
        addPersonRaw("村民");
        feed("新村民入住（耗口粮 农作物10；居住位有空）", "good");
      }
    }
  }
  // 聚落升格：人口达 30，根组织更名市政厅
  {
    const root = S.orgs.o01;
    if (root && root.name === "聚落" && S.people.length >= 30) {
      root.name = "市政厅";
      feed("聚落升格为市政厅（人口达 30）", "good");
    }
  }
  // ⑥ 训练推进（04 §三：训练组织接收整只编制组织受训；100 点内部进度=升 1 级；
  //    教官在编才有速率，中断停涨不丢；受训组织/训练营解散即取消）
  for (const camp of Object.values(S.orgs)) {
    if (camp.template !== "训练营") continue;
    const trainee = camp.settings["受训组织"] ? S.orgs[camp.settings["受训组织"]] : null;
    if (!trainee) continue;
    const n = camp.slots["教官"]?.persons.length || 0;
    if (!n) continue;   // 无教官=停摆（进度保留）
    trainee.trainProg += 4 * n * mult * dt;
    if (trainee.trainProg >= 100 - 1e-6) {   // 浮点累加边界
      trainee.trainProg = 0;
      trainee.trainLv += 1;
      const roman = ["Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ"][trainee.trainLv - 1] || trainee.trainLv;
      feed(`${trainee.name} 完成训练${roman}（${camp.name} 教官呈报）`, "good");
    }
  }
  // 总览快照：按情报链的更新周期刷新（文书回运的物理节奏；停更=快照陈旧不冻结游戏本体）
  {
    const iv = intelInterval();
    if (S.snap === null || (iv !== Infinity && S.hours - S.snap.at >= iv)) S.snap = collectSnap();
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
export function queueBuild(kind, b, item, idx, side = "右") {
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
  S.buildOrders.push({ kind, b, item: item || "", idx: idx ?? -1, side, work, done: 0 });
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
  if (d.homog && slot.persons.length >= slotCap(o, slot)) { feed(`「${fn}」坑位已满（${slotCap(o, slot)}，随仓库规模变动）`, "bad"); return; }
  if (slot.institution) { feed(`${o.name}「${fn}」撤出机构，改为人员顶岗`); slot.institution = ""; }
  slot.persons.push(pid); person(pid).org = orgId;
  feed(`${person(pid).name} 入 ${o.name}「${fn}」槽（在编）`, "good");
}
export function pullPersons(orgId, fn) {
  const slot = S.orgs[orgId]?.slots[fn]; if (!slot) return;
  for (const pid of slot.persons) person(pid).org = "";
  slot.persons = [];
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
