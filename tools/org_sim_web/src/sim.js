import { reactive } from "vue";

/* ═════════ 自然地形（城市自带；采集需要对应地形在场）——本城树林/矿洞/耕地都有 ═════════ */
export const TERRAIN = {
  "树林": { products: ["原木"], offmap: true },     // 不可到达——产出仍进场堆待运（裁决24：三线都得搬运工搬回），只是堆不设上限
  "矿洞": { products: ["铁矿"], satellite: true },  // 卫星城：唯一可在其处建卫星仓的地形
  "耕地": { products: ["农作物"], inCity: true },   // 主城内（改名耕地）
};
/* 城市库存品目录（可进仓库）。cat：basic=基础原料 / mat=材料 / prod=制品（顶栏只放 basic，全量在仓库页）。
   原料窄口径（05-经济系统 §四）：基础原料三种——原木/矿物（暂只做铁）/农作物，全部地形直出；
   木材/木板/铁锭都是工序产物（加工品），多样性靠工序不靠原料。
   进食是可选增益、不设「食物」资源；铁水/毛坯/淬火件/净药材/车料是厂内物品，不可离厂（仓库页「厂内」标签可见） */
export const RES = ["原木", "铁矿", "农作物", "茅草", "木材", "木板", "木梁", "木瓦", "门扇", "窗扇", "铁锭", "铁钉", "铁板", "绳索",
                    "铁剑", "药水", "手推车"];
export const RES_INFO = {
  "原木":   { cat: "basic", icon: "🌲", src: "伐木队采自树林——柱/椽/梁的毛料与锯解原料" },
  "铁矿":   { cat: "basic", icon: "🪨", src: "矿物·暂只做铁——采矿队采自矿洞" },
  "农作物": { cat: "basic", icon: "🌾", src: "耕地产出——入药与纤维（搓绳）原料；进食可选增益、无饥饿（机制后续）" },
  "茅草":   { cat: "mat", icon: "🌿", src: "收割副产（麦秆梳束成捆）——茅草顶铺苫料（正片 thatch 材质）" },
  "木材":   { cat: "mat", icon: "🪵", src: "锯木坊锯解原木所得（锯材通用料）" },
  "木板":   { cat: "mat", icon: "🟫", src: "锯木坊刨光木材所得——板墙/地板/门窗料" },
  "木梁":   { cat: "mat", icon: "🪓", src: "锯木坊制梁所得——梁柱构建筑的承重梁与椽" },
  "木瓦":   { cat: "mat", icon: "🧱", src: "锯木坊制瓦（木板开片）——屋面覆盖" },
  "门扇":   { cat: "mat", icon: "🚪", src: "锯木坊制门（板料拼装）——梁柱构建筑门窗安装环节到场料" },
  "窗扇":   { cat: "mat", icon: "🔲", src: "锯木坊制窗（板料拼装）——梁柱构建筑门窗安装环节到场料" },
  "铁锭":   { cat: "mat", icon: "🔩", src: "冶炼坊自产（或初始库存）" },
  "铁钉":   { cat: "mat", icon: "📌", src: "锻造坊制钉（铁锭冲打）——连接紧固件" },
  "铁板":   { cat: "mat", icon: "⬜", src: "锻造坊轧板（铁锭辗轧）——耐火铺面/器具" },
  "绳索":   { cat: "mat", icon: "🪢", src: "木器坊搓绳（农作物纤维）——绑扎/索具" },
  "铁剑":   { cat: "prod", icon: "🗡️", src: "锻造坊开刃出品——成军军械储备" },
  "药水":   { cat: "prod", icon: "🧪", src: "药剂坊熬制" },
  "手推车": { cat: "prod", icon: "🛒", src: "木器坊装配——运输队载具（运力 1.8/人时）" },
};
export const RES_CATS = [["basic", "基础原料"], ["mat", "材料"], ["prod", "制品"]];
export const BASIC_RES = RES.filter(r => RES_INFO[r].cat === "basic");

/* ═════════ 建筑（与组织独立：组织无建筑可基础运转；建筑解锁进阶槽位与设备工序） ═════════ */
/* 施工＝结构工作量制（裁决37/39）：每环节挂「工作量」（结构量，非工时）与工种，
   人把劳动力折成工作量——时长＝工作量÷施工效率，效率因人（属性）因工种而异，时长是涌现值。
   工种＝专门作队组织（裁决40）：木匠活走木匠队（吃 cft 灵巧）、小工活走小工队（吃 str 力气），
   两队各自出力、互不抢人——木匠立架时小工照样备料夯地（真并行）。
   建筑形制决定工序链（不同类型不同工作流，裁决41）：
   棚（开敞）＝无墙无门窗：场地→地基→立架→铺椽→铺顶→夯地（锯台防雨即可，围护全免）
   屋（围木）＝圆木垒墙板皮顶：全链，墙体原木直用（自举段）
   架（梁柱）＝锯材梁柱+板墙+木瓦顶+厂制门窗铁件（锻造坊一类重设施） */
const PHASE_LIB = {
  备料: { trade: "小工", vol: 4, cost: {} },                    // 材料搬运到位
  场地: { trade: "小工", vol: 3, cost: {} },                    // 清表放线夯实
  地基: { trade: "木匠", vol: 4, cost: { "原木": 2 } },         // 圆木地梁
  立架: { trade: "木匠", vol: 8, cost: { "原木": 6 } },         // 立柱架梁（架级换锯材梁）
  铺椽: { trade: "木匠", vol: 6, cost: { "原木": 2 } },         // 圆木椽（架级换木梁椽）
  铺顶: { trade: "瓦匠", vol: 5, cost: { "茅草": 4 } },         // 屋面归瓦匠线（茅草/木瓦都是屋面匠铺——现实口径）
  筑墙: { trade: "瓦匠", vol: 6, cost: { "原木": 4 } },         // 砌墙归瓦匠线（现实：砌筑是泥水匠的活；架级换板墙）
  门窗: { trade: "木匠", vol: 4, cost: { "木板": 2 } },         // 现制门窗（架级厂制到场安装）
  粉刷: { trade: "瓦匠", vol: 3, cost: {} },                    // 抹灰归瓦匠线（现实：抹灰是泥水匠的活，小工只和灰）
  夯地: { trade: "小工", vol: 2, cost: {} },                    // 夯土地面（就地取土；架级换木地板）
};
const PHASE_DEPS = { 备料: [], 场地: [], 地基: ["场地"], 立架: ["地基", "备料"], 铺椽: ["立架"],
  铺顶: ["铺椽"], 筑墙: ["铺顶"], 夯地: ["立架"], 门窗: ["筑墙"], 粉刷: ["筑墙"] };   // 先顶后墙（营造实证）
/* 架级环节换料（梁柱/板墙/瓦顶/厂制门窗） */
const PHASE_LIB_FRAMED = {
  立架: { cost: { "原木": 2, "木梁": 4 } },
  铺椽: { cost: { "木梁": 2 } },
  铺顶: { vol: 6, cost: { "木瓦": 4 } },
  筑墙: { cost: { "木板": 6 } },
  门窗: { cost: { "门扇": 1, "窗扇": 1, "铁钉": 2 } },
  夯地: { trade: "木匠", cost: { "木板": 2 } },
};
/* 形制→环节集合（棚=开敞无围护；屋=围木全链；架=梁柱换料） */
const FORM_PHASES = { 棚: ["备料", "场地", "地基", "立架", "铺椽", "铺顶", "夯地"],
  屋: Object.keys(PHASE_LIB), 架: Object.keys(PHASE_LIB) };
export const BUILDINGS = {
  "市政厅": { prebuilt: true, desc: "城市根组织所在" },
  "仓库":   { prebuilt: true, form: "屋", floors: 3, desc: "资源与制品的集中存放；每座+容量、搬运坑位随座数增长" },
  "伐木小屋": { form: "屋", floors: 3, desc: "伐木队办公与工具场所（无它也能伐：探测/记录被禁）", interior: [
      { item: "办公桌椅", cost: { "木材": 6 }, work: 6, w: 2, unlock: "解锁伐木队的探测/记录槽" },
      { item: "工具架",   cost: { "木板": 4 }, work: 6, w: 1, effect: "伐木速率+25%" },
      { item: "额外椅子", cost: { "木板": 2 }, work: 3, w: 1, effect: "木材信息联络更快" } ] },
  "锯木坊": { form: "棚", floors: 1, desc: "锯解→制梁→制瓦→刨光→制门→制窗：原木出材，板出成品（开敞锯棚）", interior: [
      { item: "锯架",   cost: { "木材": 8 }, work: 8, w: 2, unlock: "锯解工序（原木→木材）" },
      { item: "制梁台", cost: { "木材": 6 }, work: 6, w: 2, unlock: "制梁工序（原木→木梁）" },
      { item: "制瓦刀", cost: { "木板": 3 }, work: 5, w: 1, unlock: "制瓦工序（木板→木瓦，需木工）" },
      { item: "刨台",   cost: { "木板": 2 }, work: 5, w: 2, unlock: "刨光工序（木材→木板，需木工）" },
      { item: "制门台", cost: { "木板": 4 }, work: 5, w: 2, unlock: "制门工序（木板×2→门扇，需木工）" },
      { item: "制窗台", cost: { "木板": 2 }, work: 3, w: 1, unlock: "制窗工序（木板→窗扇，需木工）" } ] },
  "锻造坊": { form: "架", floors: 3, desc: "熔炼→锻打→淬火→开刃→制钉→轧板，出铁剑/铁钉/铁板（半成品不出厂）", interior: [
      { item: "熔炉",   cost: { "木材": 8, "木板": 4, "铁矿": 2 }, work: 10, w: 2, unlock: "熔炼工序（铁矿+木材→铁水）" },
      { item: "铁砧",   cost: { "铁矿": 4 }, work: 8, w: 2, unlock: "锻打工序（铁水/铁锭→毛坯）" },
      { item: "水槽",   cost: { "木材": 6 }, work: 5, w: 1, unlock: "淬火工序（毛坯→淬火件）" },
      { item: "磨石",   cost: { "铁矿": 2 }, work: 5, w: 1, unlock: "开刃工序（淬火件→铁剑，需锻造）" },
      { item: "制钉模", cost: { "铁锭": 2, "木材": 2 }, work: 6, w: 1, unlock: "制钉工序（铁锭→铁钉×4，需锻造）" },
      { item: "轧辊",   cost: { "铁锭": 3 }, work: 6, w: 1, unlock: "轧板工序（铁锭→铁板，需锻造）" },
      { item: "风箱",   cost: { "木材": 4, "铁矿": 1 }, work: 4, w: 1, unlock: "风箱岗：拉风箱助熔，熔炼提速（鼓风提炉温）" } ] },
  "药剂坊": { form: "屋", floors: 3, desc: "农作物 → 净药材 → 药水", interior: [
      { item: "切药刀", cost: { "铁矿": 1 }, work: 4, w: 1, unlock: "炮制工序（农作物→净药材）" },
      { item: "药炉",   cost: { "木材": 8 }, work: 6, w: 2, unlock: "熬制工序（净药材→药水，需制药）" } ] },
  "训练场": { form: "架", floors: 3, desc: "教官与受训编制的训练场地", patch: { 门窗: { cost: { "门扇": 1, "铁钉": 2, "绳索": 2 } } }, interior: [
      { item: "木人桩", cost: { "木材": 6 }, work: 6, w: 1, unlock: "解锁教官岗" },
      { item: "靶场",   cost: { "木板": 2, "绳索": 2 }, work: 5, w: 2, effect: "演武器材（机制后续）" } ] },
  "兵营": { form: "架", floors: 3, desc: "常备军的营房", interior: [] },
  "办公楼": { form: "屋", floors: 3, desc: "人事与组织的办公场所", interior: [
      { item: "档案柜", cost: { "木材": 5 }, work: 5, w: 2, unlock: "人事岗就绪" } ] },
  "书院": { form: "架", floors: 3, desc: "研究与实验的场所", patch: { 门窗: { cost: { "门扇": 1, "铁钉": 2, "绳索": 2 } } }, interior: [
      { item: "书架",   cost: { "木板": 4 }, work: 5, w: 2, unlock: "解锁课题管理岗" },
      { item: "实验台", cost: { "铁矿": 2, "木板": 2 }, work: 6, w: 2, unlock: "解锁实验岗" } ] },
  "民居": { form: "屋", floors: 3, desc: "村民居住位（每层基准4位，装床铺翻倍）；有空位，移民来投；可加层至木质上限2层", interior: [
      { item: "床铺", cost: { "木材": 4 }, work: 4, w: 1, effect: "居住位+4（按层折算）" } ] },
  "木工房": { form: "架", floors: 3, desc: "备料→搓绳→装配，出手推车/绳索（车料为厂内物品）", interior: [
      { item: "木工台", cost: { "木材": 8, "铁矿": 2 }, work: 8, w: 2, unlock: "备料工序（木板+铁锭→车料）" },
      { item: "搓绳架", cost: { "木材": 4 }, work: 4, w: 2, unlock: "搓绳工序（农作物×2→绳索）" },
      { item: "组装架", cost: { "木材": 4, "铁矿": 1 }, work: 5, w: 1, unlock: "装配工序（车料→手推车，需木工）" } ] },
  "冶炼坊": { form: "架", floors: 3, desc: "矿石入炉炼铁，出铁锭", patch: { 门窗: { cost: { "门扇": 1, "窗扇": 1, "铁矿": 2 } } }, interior: [
      { item: "冶炼炉", cost: { "铁矿": 6, "木板": 4 }, work: 12, w: 2, unlock: "冶炼工序（铁矿+木材→铁锭，需冶炼）" } ] },
};

/* ═════════ 组织模板。host＝可入驻的槽名（选中空槽即弹出该槽可构筑的子组织，可递归）；
   pos＝岗位用人类型（标签色）：must=必须（至少一人该组织才能开工，人数可弹性）
   · semi=半必须（需人运行但不必时刻有人，可从本队别岗移调）
   · gain=增益（无人也行，只是未解锁/缺失该功能——解锁类）；
   role＝该岗职能标注（放人=放机构同一效果，效果由在编的人提供——裁决49）；bldg＝需进驻的建筑类型（03 §一）═════════ */
export const ORGS = {
  "生产局": { host: "生产", slots: [
      { fn: "采集", n: 1, pos: "gain", role: "泛采集兜底 0.4/人时；采集中心可入驻下辖三线" },
      { fn: "建造", n: 1, pos: "gain", role: "督造；工程队可入驻成建制施工" },
      { fn: "制造", n: 1, pos: "gain", role: "跟单；制造中心可入驻统筹各坊" } ] },
  "采集中心": { host: "采集", slots: [
      { fn: "伐木", n: 1, pos: "gain", role: "原木产出线" },
      { fn: "采矿", n: 1, pos: "gain", role: "铁矿产出线" },
      { fn: "农垦", n: 1, pos: "gain", role: "农作物产出线" } ] },
  "制造中心": { host: "制造", slots: [
      { fn: "锯木", n: 1, pos: "gain", role: "原木→木材→木板" },
      { fn: "锻造", n: 1, pos: "gain", role: "铁矿→铁剑" },
      { fn: "制药", n: 1, pos: "gain", role: "农作物→药水" },
      { fn: "木器", n: 1, pos: "gain", role: "木板+铁锭→手推车（载具）" },
      { fn: "冶炼", n: 1, pos: "gain", role: "铁矿→铁锭" } ] },
  /* 工程队＝施工项目部（裁决52，按现实双层结构）：
     管理层＝大匠（掌墨师式：项目经理+总工+施工员+测量+设计一身——墨线即图纸）＋监工（材料/质检/账目）；
     劳务层＝木作班/泥瓦班入驻 木作/泥瓦 槽（每班：班组长带班+匠人+配属小工），小规模可直派匠人；
     机动小工直属队内（跨班调度）。石作班待石料经济开 */
  "工程队": { host: "建造", slots: [
      { fn: "大匠", n: 1, pos: "must", lead: true, role: "掌墨带班：放线派工验活一身兼——在编才解锁内部结构预览（墨线即图纸）" },
      { fn: "监工", n: 1, pos: "gain", role: "材料收发、工序核验、工账" },
      { fn: "木作", n: 4, homog: true, pos: "gain", role: "木匠活——直派匠人或放木作班整班入驻（构架/铺椽/门窗）" },
      { fn: "泥瓦", n: 4, homog: true, pos: "gain", role: "瓦匠活——直派匠人或放泥瓦班整班入驻（砌墙/屋面/抹灰）" },
      { fn: "小工", n: 2, homog: true, pos: "gain", role: "机动小工——跨班调度（备料/场地/夯地；各班另有配属小工）" } ] },
  /* 匠班（裁决51/52：班组长带班+匠人+配属小工＝有真分工的班组，非纯劳动力池） */
  "木作班": { host: "木作", slots: [
      { fn: "班组长", n: 1, pos: "must", lead: true, role: "木匠带班——自己也上构架" },
      { fn: "木匠", n: 3, homog: true, pos: "must", role: "构架/铺椽/门窗" },
      { fn: "小工", n: 2, homog: true, pos: "must", role: "配属小工——供料扶料" } ] },
  "泥瓦班": { host: "泥瓦", slots: [
      { fn: "班组长", n: 1, pos: "must", lead: true, role: "瓦匠带班——自己也砌墙" },
      { fn: "瓦匠", n: 3, homog: true, pos: "must", role: "砌墙/屋面/抹灰" },
      { fn: "小工", n: 2, homog: true, pos: "must", role: "配属小工——和灰供砖" } ] },
  "运输队": { host: "运输", slots: [
      { fn: "调度", n: 1, pos: "gain", role: "减轻未通报场地的搬运损耗", lead: true },
      { fn: "库管", n: 1, pos: "must", role: "在岗搬运才运转" },
      { fn: "搬运", n: 5, homog: true, pos: "must", role: "负责搬运" } ] },
  "伐木队": { host: "伐木", bldg: "伐木小屋", slots: [
      { fn: "伐木队长", n: 1, pos: "must", terrain: "树林", lead: true, role: "带班伐木——自己也伐木" },
      { fn: "伐木", n: 4, homog: true, pos: "must", terrain: "树林", role: "负责伐木" },
      { fn: "木材信息", n: 1, pos: "semi", role: "收集木材线信息呈递给你" },
      { fn: "探测", n: 1, pos: "gain", req: { b: "伐木小屋", item: "办公桌椅" }, role: "收集林木资源情报呈递给你" },
      { fn: "记录", n: 1, pos: "gain", req: { b: "伐木小屋", item: "办公桌椅" }, role: "记录木材出入并呈递给你" } ] },
  "采矿队": { host: "采矿", slots: [
      { fn: "挖矿队长", n: 1, pos: "must", terrain: "矿洞", lead: true, role: "带班挖矿——自己也下矿" },
      { fn: "挖矿", n: 4, homog: true, pos: "must", terrain: "矿洞", role: "负责挖矿" },
      { fn: "支护", n: 1, pos: "gain", role: "架坑木支撑坑道——矿场堆容 +20/人" },
      { fn: "提升", n: 1, pos: "gain", role: "坑口吊运——矿石出坑快 1/4（同工具架物理口径）" },
      { fn: "矿石信息", n: 1, pos: "semi", role: "收集矿石线信息呈递给你" } ] },
  "农垦队": { host: "农垦", slots: [
      { fn: "耕作队长", n: 1, pos: "must", terrain: "耕地", lead: true, role: "带班耕作——自己也下地" },
      { fn: "耕作", n: 4, homog: true, pos: "must", terrain: "耕地", role: "负责耕作" },
      { fn: "选种", n: 1, pos: "gain", role: "留优种作来年种籽" },
      { fn: "农情信息", n: 1, pos: "semi", role: "收集农情信息呈递给你" } ] },
  "锯木坊": { host: "锯木", bldg: "锯木坊", slots: [
      { fn: "锯解", n: 1, pos: "semi", step: 0, role: "原木开成木材", lead: true },
      { fn: "制梁", n: 1, pos: "semi", step: 1, role: "原木取方成梁" },
      { fn: "制瓦", n: 1, pos: "semi", step: 2, role: "木板开片成瓦" },
      { fn: "刨光", n: 1, pos: "semi", step: 3, role: "木材刨成木板" },
      { fn: "制门", n: 1, pos: "semi", step: 4, role: "木板拼装门扇" },
      { fn: "制窗", n: 1, pos: "semi", step: 5, role: "木板拼装窗扇" } ],
    steps: [ { name: "锯解", equip: "锯架", inCity: { "原木": 1 }, outCity: { "木材": 1 } },
             { name: "制梁", equip: "制梁台", inCity: { "原木": 1 }, outCity: { "木梁": 1 } },
             { name: "制瓦", equip: "制瓦刀", inCity: { "木板": 1 }, outCity: { "木瓦": 1 }, art: "木工" },
             { name: "刨光", equip: "刨台", inCity: { "木材": 1 }, outCity: { "木板": 1 }, art: "木工" },
             { name: "制门", equip: "制门台", inCity: { "木板": 2 }, outCity: { "门扇": 1 }, art: "木工" },
             { name: "制窗", equip: "制窗台", inCity: { "木板": 1 }, outCity: { "窗扇": 1 }, art: "木工" } ] },
  "锻造坊": { host: "锻造", bldg: "锻造坊", slots: [
      { fn: "风箱", n: 1, pos: "semi", role: "拉风箱助熔——鼓风提炉温", lead: true },
      { fn: "熔炼", n: 1, pos: "semi", step: 0, role: "铁矿+木材化铁水" },
      { fn: "锻打", n: 1, pos: "semi", step: 1, role: "铁水或铁锭锻毛坯" },
      { fn: "淬火", n: 1, pos: "semi", step: 2, role: "毛坯淬火" },
      { fn: "开刃", n: 1, pos: "semi", step: 3, role: "淬火件开刃成剑" },
      { fn: "制钉", n: 1, pos: "semi", step: 4, role: "铁锭冲打成钉" },
      { fn: "轧板", n: 1, pos: "semi", step: 5, role: "铁锭辗轧成板" } ],
    steps: [   // 古代冶炼/锻造分工；半成品为厂内物品不可离厂；锻打原料偏好见组织面板
      { name: "熔炼", equip: "熔炉", inCity: { "铁矿": 1, "木材": 1 }, wip: "铁水" },
      { name: "锻打", equip: "铁砧", wipIn: "铁水", altCity: { "铁锭": 1 }, wip: "毛坯" },
      { name: "淬火", equip: "水槽", wipIn: "毛坯", wip: "淬火件" },
      { name: "开刃", equip: "磨石", wipIn: "淬火件", outCity: { "铁剑": 1 }, art: "锻造" },
      { name: "制钉", equip: "制钉模", inCity: { "铁锭": 1 }, outCity: { "铁钉": 4 }, art: "锻造" },
      { name: "轧板", equip: "轧辊", inCity: { "铁锭": 1 }, outCity: { "铁板": 1 }, art: "锻造" } ] },
  "药剂坊": { host: "制药", bldg: "药剂坊", slots: [
      { fn: "炮制", n: 1, pos: "semi", step: 0, role: "农作物炮制净药材", lead: true },
      { fn: "熬制", n: 1, pos: "semi", step: 1, role: "净药材熬成药水" } ],
      steps: [
        { name: "炮制", equip: "切药刀", inCity: { "农作物": 1 }, wip: "净药材" },
        { name: "熬制", equip: "药炉", wipIn: "净药材", outCity: { "药水": 1 }, art: "制药" } ] },
  "木器坊": { host: "木器", bldg: "木工房", slots: [
      { fn: "备料", n: 1, pos: "semi", step: 0, role: "木板铁锭备成车料", lead: true },
      { fn: "搓绳", n: 1, pos: "semi", step: 1, role: "农作物纤维搓成绳索" },
      { fn: "装配", n: 1, pos: "semi", step: 2, role: "车料装成手推车" } ],
    steps: [
      { name: "备料", equip: "木工台", inCity: { "木板": 2, "铁锭": 1 }, wip: "车料" },
      { name: "搓绳", equip: "搓绳架", inCity: { "农作物": 2 }, outCity: { "绳索": 1 } },
      { name: "装配", equip: "组装架", wipIn: "车料", outCity: { "手推车": 1 }, art: "木工" } ] },
  /* 职能槽下辖的专门组织（任意槽可下辖；信息/库管槽内的精细化示例，可继续递归） */
  "林务所": { host: "木材信息", slots: [
      { fn: "巡看", n: 2, homog: true, pos: "must", role: "巡看林中堆存与路况", lead: true },
      { fn: "记档", n: 1, pos: "gain", role: "汇总木材台账" } ] },
  "矿务所": { host: "矿石信息", slots: [
      { fn: "巡看", n: 2, homog: true, pos: "must", role: "巡看矿场堆存", lead: true },
      { fn: "记档", n: 1, pos: "gain", role: "汇总矿石台账" } ] },
  "农务所": { host: "农情信息", slots: [
      { fn: "巡看", n: 2, homog: true, pos: "must", role: "巡看田场堆存", lead: true },
      { fn: "记档", n: 1, pos: "gain", role: "汇总农情台账" } ] },
  "库务所": { host: "库管", slots: [
      { fn: "收发", n: 1, pos: "must", role: "出入库过秤记账", lead: true },
      { fn: "盘点", n: 1, pos: "gain", role: "清点库房核对账实" } ] },
  "人事局": { host: "行政", bldg: "办公楼", slots: [
      { fn: "人事", n: 1, pos: "must", lead: true, req: { b: "办公楼", item: "档案柜" }, role: "自动补员：待业者补进缺员的必须岗（在编越多补得越勤）" },
      { fn: "组织管理", n: 1, pos: "gain", role: "组织编制管理（自适应扩建与改编，01 §4.6）" } ] },
  "情报局": { host: "情报", slots: [
      { fn: "汇总", n: 1, pos: "must", role: "汇总各线呈递，生成一站式总览", lead: true },
      { fn: "采编", n: 4, homog: true, pos: "must", role: "到各信息岗采编一线情报" },
      { fn: "抄送", n: 1, pos: "gain", role: "把总览分发到各指令面板" } ] },
  "冶炼坊": { host: "冶炼", bldg: "冶炼坊",
      slots: [ { fn: "冶炼", n: 1, pos: "semi", step: 0, role: "铁矿配柴入炉炼锭", lead: true } ],
      steps: [ { name: "冶炼", equip: "冶炼炉", inCity: { "铁矿": 1, "木材": 1 }, outCity: { "铁锭": 1 }, art: "冶炼" } ] },
  "常备军": { host: "军事", bldg: "兵营", slots: [
      { fn: "军事", n: 1, pos: "must", role: "在编即可动员", lead: true },
      { fn: "军需", n: 1, pos: "gain", role: "军械领用配发登记" },
      { fn: "训练", n: 1, pos: "gain", role: "放训练营成建制施训" } ] },
  "训练营": { host: "训练", bldg: "训练场", slots: [
      { fn: "训练管理", n: 1, pos: "gain", role: "排训练计划", lead: true },
      { fn: "教官", n: 4, homog: true, pos: "must", req: { b: "训练场", item: "木人桩" }, role: "施训教官" },
      { fn: "器材管理", n: 1, pos: "gain", role: "维护训练器材" } ] },
  "科研院": { host: "教育", bldg: "书院", slots: [
      { fn: "课题管理", n: 1, pos: "gain", lead: true, req: { b: "书院", item: "书架" }, role: "选题与立项" },
      { fn: "实验", n: 3, homog: true, pos: "must", req: { b: "书院", item: "实验台" }, role: "产出新技能，长在本人身上" },
      { fn: "文献记录", n: 1, pos: "gain", role: "汇总技能台账并呈递给你" } ] },
};
export const HALL_SLOT_KEYS = ["市长", "军事", "行政", "生产", "运输", "教育", "情报"];
/* 成军＝军械储备（铁剑×2 入库）+ 集结口粮（农作物×50）——制品与原料的实物资费 */
export const LATE_COST = { "常备军": { res: { "农作物": 50, "铁剑": 2 } }, "训练营": { res: { "木材": 15 } },
                           "科研院": { res: { "木板": 10 }, prereqSkill: "识字" } };
/* 空槽的可构筑候选（按槽名匹配 host——组织树即构筑树；别名＝放弃统筹层直挂单线的路径偏好） */
export const SLOT_ALIAS = { "采集": ["伐木队", "采矿队", "农垦队"], "制造": ["锯木坊", "锻造坊", "药剂坊", "木器坊"] };
export const slotCandidates = fn => {
  const base = Object.entries(ORGS).filter(([, t]) => t.host === fn).map(([n]) => n);
  return [...base, ...(SLOT_ALIAS[fn] || []).filter(n => !base.includes(n))];
};
/* 递归允许专门化，但同型自嵌套（伐木队槽里再放伐木队）无意义——由调用侧按宿主模板排除 */

/* ── 中间层扩编（创始人裁决：集团化）──母槽除直接放单厂/单队外，可放「总坊/总队」管理层，
   下辖多株同型厂队扩产能——如国家级科学院下辖省科学院、军下辖营。总管为占位统筹岗（机制后续）；
   下辖槽放单株组织（各需自驻一座建筑，createBlocked 既有硬前提）；中间层不再嵌套（子槽候选里没有总坊） */
const MIDDLES = [
  ["锯木", "锯木总坊", "锯木坊"], ["锻造", "锻造总坊", "锻造坊"], ["制药", "药剂总坊", "药剂坊"],
  ["木器", "木器总坊", "木器坊"], ["冶炼", "冶炼总坊", "冶炼坊"],
  ["伐木", "伐木总队", "伐木队"], ["采矿", "采矿总队", "采矿队"], ["农垦", "农垦总队", "农垦队"],
  ["建造", "工程总队", "工程队"],
];
for (const [host, name, leaf] of MIDDLES) {
  ORGS[name] = { host, middle: true, slots: [
    { fn: "总管", n: 1, pos: "gain", role: "排产与统筹：下辖厂队的原料计划（机制后续）" },
    { fn: leaf, n: 1, pos: "gain", role: `下辖${leaf}——放单株组织（各需自驻一座建筑）` },
    { fn: leaf, n: 1, pos: "gain", role: `下辖${leaf}——放单株组织（各需自驻一座建筑）` },
    { fn: leaf, n: 1, pos: "gain", role: `下辖${leaf}——放单株组织（各需自驻一座建筑）` } ] };
  SLOT_ALIAS[leaf] = [leaf]; SLOT_ALIAS[leaf + "2"] = [leaf]; SLOT_ALIAS[leaf + "3"] = [leaf];
}
/* 组织控制面板选项（实际游戏为各组织专属的复杂精美 UI，sim 只模拟基础功能；
   选不同机构＝功能实现路径的偏好，如同计划 or 市场） */
export const ORG_PANELS = {
  "常备军": [ { key: "兵役制度", choices: [["动员兵役", "耕战一体：战时集结，动员时产率减半"],
                                            ["常备兵役", "职业兵维持需后勤供给（后续），动员不减产率"]] } ],
  "工程队": [ { key: "自动扩建", choices: [["关", "全部施工手动排队"],
                                          ["开", "仓库近满且无在办建造单时，自动排队再建一座（保底不压主线）"]] } ],
  "运输队": [ { key: "载具", choices: [["人力搬运", "1.2/人时"],
                                        ["手推车", "1.8/人时——一队一车按队占编、库中需有车（木器坊出品）", { need: "手推车" }]] },
              { key: "装卸规则", choices: [["均匀分运", "各场地按堆量比例搬运"],
                                            ["大宗优先", "先清最大堆——场地少顶格停采，小堆排后"]] },
              { key: "运输计划", choices: [["均匀", "按堆量比例分运（无计划偏好）"],
                                            ["偏重原木", "原木线运力×2——调度在岗才生效（排单是调度的活）"],
                                            ["偏重铁矿", "铁矿线运力×2——调度在岗才生效"],
                                            ["偏重农作物", "农作物线运力×2——调度在岗才生效"]] } ],
  "锯木坊": [ { key: "出材偏好", choices: [["优先木材", "锯解多出力：木材供燃料与建材"],
                                          ["优先木板", "刨光多出力：木板供下游制造"]] } ],
  "锻造坊": [ { key: "锻打原料", choices: [["铁水优先", "以厂内自炼铁水为主"],
                                            ["铁锭优先", "以库存铁锭为主，省下燃料"]] } ],
  "科研院": [ { key: "选题", choices: [["实用优先", "先解当前生产急用（机制后续）"],
                                        ["底层探究", "先钻基础原理（机制后续）"]] } ],
};
/* 按需生产（自动化审计：工厂此前有料就跑必堆满）——库存目标：产物达标记线即歇线，降库存自动复工 */
for (const t of ["锯木坊", "锻造坊", "药剂坊", "木器坊", "冶炼坊"])
  (ORG_PANELS[t] ||= []).push({ key: "库存目标", choices: [
    ["不限", "有原料就生产（不设停线）"],
    ["满20", "产物库存≥20 歇线——满仓歇工、低于自动复工（军需式按需生产）"],
    ["满40", "产物库存≥40 歇线"],
    ["满80", "产物库存≥80 歇线"],
    ["满160", "产物库存≥160 歇线"]] });
/* 建不了的原因（拒止反馈落在按钮态上）：前提→资源，与构筑同序 */
export function createBlocked(name) {
  const t = ORGS[name];
  if (t?.bldg && !(S.buildings[t.bldg] || []).some(i => !i.org))
    return `需先再建一座${t.bldg}（该类组织必须依附建筑）`;
  const cost = LATE_COST[name];
  if (!cost) return "";
  if (cost.prereqSkill && !S.people.some(p => p.org && p.skills.includes(cost.prereqSkill)))
    return `明面前提未满足：在编有人会「${cost.prereqSkill}」`;
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
  orgTasks: [],
  cityL: [], cityR: [], citySat: [], autoCd: 0, popCd: 0, seed: 0, wear: { cart: 0, sword: 0 },
  knobs: { gather: 0.8, deptGather: 0.4, haul: 1.2, craft: 0.6, uninfo: 0.5, buf: 40, cap: 600 },
  intake: { "原木": false, "铁矿": false, "农作物": false },
});

/* 聚落开局：根组织叫「聚落」（人口达 30 升格更名市政厅）；自带市政厅与仓库各一座，
   一切组织与建筑从零搭起。完全体展示样板见 loadDemo()（参数面板可载入） */
export function reset(seed) {
  const fresh = {
    hours: 0, speed: 0, seq: { p: 0, o: 0 },
    people: [], orgs: {}, order: [],
    res: { "原木": 30, "铁矿": 0, "农作物": 30, "茅草": 10, "木材": 20, "木板": 10, "铁锭": 0, "铁剑": 0, "药水": 0, "手推车": 0, "木梁": 0, "木椽": 0, "木瓦": 0, "门扇": 0, "窗扇": 0, "铁钉": 0, "铁板": 0, "绳索": 0 },
    // 自举本金（工作量制口径）：首屋（民居·屋 原7板3）+锯木坊（开敞棚 原10板2）+锯架（木8）+床（木4）——
    // 板为一次性垫底，此后板/梁/椽/瓦/门窗全自产；低于此开局锁死（全城唯一木材产能是装了锯架的锯木坊）
    buf: {}, wip: {}, buildings: {}, buildOrders: [],
    mobilized: false, borrows: {},
    sel: null, selSlot: null, feed: [], rates: {}, snap: null,
    orgTasks: [], cityL: [], cityR: [], citySat: [], autoCd: 0, popCd: 0, seed: 0, wear: { cart: 0, sword: 0 },
    intake: { "原木": false, "铁矿": false, "农作物": false },   // 收货政策默认全关（裁决34）：产出先堆产地空地
  };
  Object.assign(S, fresh);
  for (const b of Object.keys(BUILDINGS))
    S.buildings[b] = BUILDINGS[b].prebuilt ? [{ interior: {}, org: "" }] : [];
  // 随机初始布局：开局仓库随机落某一翼（每局不同）；seed 留档可复现
  S.seed = Number(seed) || Math.floor(Math.random() * 1e6);   // 传入 seed＝按种子复现初始布局（参数面板入口）
  const rng = mulberry32(S.seed);
  (rng() < 0.5 ? S.cityL : S.cityR).push({ b: "仓库", inst: 0 });
  for (const [site, t] of Object.entries(TERRAIN))
    for (const p of t.products) S.buf[site + "|" + p] = 0;   // 三线都有场地堆（树林/耕地堆不设上限）
    S.buf["耕地|茅草"] = 0;   // 收割副产线（与农作物同堆同运）
  const hall = addOrgRaw("市政厅", 1, "hall");
  hall.name = "聚落";
  for (const key of HALL_SLOT_KEYS)
    hall.slots[key] = { def: { fn: key, n: 1, pos: key === "市长" ? "must" : "gain",
      role: { "市长": "统辖聚落（你）", "军事": "掌军，在编即可动员", "行政": "管理人事与组织",
              "生产": "辖采集/建造/制造三线", "运输": "启用物流系统", "教育": "主办教育与研究",
              "情报": "生成一站式信息总览" }[key] },
      persons: [], institution: "", product: "" };
  addPersonRaw("你", { attr: { str: 5, int: 6, agi: 5, cft: 5, cmd: 7 }, skills: ["识字"] });
  hall.slots["市长"].persons = ["p01"]; S.people[0].org = hall.id;
  addPersonRaw("动员官", { attr: { str: 6, int: 4, agi: 5, cft: 4, cmd: 6 }, skills: [] });
  hall.slots["军事"].persons = ["p02"]; S.people[1].org = hall.id;
  for (let i = 0; i < 8; i++) { addPersonRaw("村民");   // 创始班底基本技能全有（裁决48）；技能稀缺随移民进场
    S.people[S.people.length - 1].skills = [...ARTS]; }
  feed("聚落开局：根组织「聚落」+市政厅/仓库各一座。选空槽派人或构筑组织，从零搭起一切");
  S.snap = collectSnap();
}

/* 完全体样板（原默认展示）：参数面板「载入完全体」可一键载入 */
export function loadDemo() {
  reset();
  S.intake = { "原木": true, "铁矿": true, "农作物": true };   // 样板开三线收货——满员运转的完全体得真搬运（开局默认全关是另一回事，裁决34）
  S.people = []; S.seq.p = 0;   // 满编名单重建（reset 的开局 10 人让位；须在 addPersonRaw 之前）
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
  inst("兵营"); inst("办公楼", "档案柜"); inst("书院", "书架", "实验台");
  inst("药剂坊", "切药刀", "药炉");
  inst("木工房", "木工台", "组装架");
  addPersonRaw("你");
  addPersonRaw("动员官");
  for (let i = 0; i < 46; i++) addPersonRaw("村民");   // 扩编 46：完全体满编不再干涸（情报/科研此前 0 人）——床位 6 屋×8=48 正好
  /* 复用 reset() 已建的根组织 o01（修复：曾另建 o02 致双根并存——情报局挂在 o02 名下，
     intelInterval 读 o01 → 完全体样板总览永久停更，僵尸聚落还会被升格逻辑二次改名） */
  const hall = S.orgs.o01;
  hall.name = "市政厅"; hall.tier = 3;
  hall.slots["市长"].persons = []; hall.slots["军事"].persons = [];   // 让位给下方满编名单
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
  const forgeHQ = addOrgRaw("锻造总坊", 2, ""); place(works, "锻造", forgeHQ);   // 中间层示例：制造中心·锻造 → 锻造总坊 → 锻造坊
  const forge = addOrgRaw("锻造坊", 2, ""); place(forgeHQ, "锻造坊", forge);
  const pharmacy = addOrgRaw("药剂坊", 2, ""); place(works, "制药", pharmacy);
  const smelter = addOrgRaw("冶炼坊", 2, ""); place(works, "冶炼", smelter);
  const cartshop = addOrgRaw("木器坊", 2, ""); place(works, "木器", cartshop);
  const haul = addOrgRaw("运输队", 2, ""); place(hall, "运输", haul);
  const store = addOrgRaw("库务所", 2, ""); place(haul, "库管", store);   // 机构入驻库管槽＝库管履职
  const army = addOrgRaw("常备军", 2, ""); place(hall, "军事", army);
  army.slots["军事"].persons = ["p02"]; S.people[1].org = army.id;
  const camp = addOrgRaw("训练营", 2, ""); place(army, "训练", camp);
  const sci = addOrgRaw("科研院", 2, ""); place(hall, "教育", sci);
  const intel = addOrgRaw("情报局", 2, ""); place(hall, "情报", intel);
  const hr = addOrgRaw("人事局", 2, ""); place(hall, "行政", hr);
  /* 满员运转（游标式分配：take(n) 依序领待业者，加减编制不再手工数格子） */
  const pool = vill(); let cur = 0;   // 快照池：曾误在收缩中的待业列表上推进游标，越取越跳、二十人后干涸
  const take = n => { const ids = pool.slice(cur, cur + n); cur += n; return ids; };
  staff(lumber, "伐木队长", 1, take(1)); staff(lumber, "伐木", 2, take(2));
  staff(mining, "挖矿队长", 1, take(1)); staff(mining, "挖矿", 2, take(2));
  staff(farm, "耕作队长", 1, take(1)); staff(farm, "耕作", 2, take(2));
  staff(haul, "调度", 1, take(1)); staff(store, "收发", 1, take(1)); staff(haul, "搬运", 3, take(3));
  staff(eng, "大匠", 1, take(1)); staff(eng, "监工", 1, take(1));
  const woody = addOrgRaw("木作班", 2, ""); place(eng, "木作", woody);   // 匠班入驻（裁决52：班组长带班+匠人+配属小工）
  const mason = addOrgRaw("泥瓦班", 2, ""); place(eng, "泥瓦", mason);
  staff(woody, "班组长", 1, take(1)); staff(woody, "木匠", 2, take(2)); staff(woody, "小工", 1, take(1));
  staff(mason, "班组长", 1, take(1)); staff(mason, "瓦匠", 2, take(2)); staff(mason, "小工", 1, take(1));
  staff(eng, "小工", 1, take(1));   // 机动小工直属大匠
  staff(forge, "风箱", 1, take(1)); staff(forge, "熔炼", 1, take(1)); staff(forge, "锻打", 1, take(1));
  staff(forge, "淬火", 1, take(1)); staff(forge, "开刃", 1, take(1));
  staff(sawmill, "锯解", 2, take(2));   // 两名锯工：样板实测原木堆积木材断供的瓶颈针（锯解1人转不过熔炼耗木）
  staff(pharmacy, "炮制", 1, take(1)); staff(pharmacy, "熬制", 1, take(1));
  staff(cartshop, "备料", 1, take(1));   // 木器坊一人厂：备料在编，装配经移调语义照常开工（工时均摊）
  staff(smelter, "冶炼", 1, take(1));
  staff(hr, "人事", 1, take(1));
  staff(camp, "训练管理", 1, take(1)); staff(camp, "教官", 1, take(1));
  staff(intel, "汇总", 1, take(1)); staff(intel, "采编", 2, take(2));
  staff(sci, "课题管理", 1, take(1)); staff(sci, "实验", 2, take(2)); staff(sci, "文献记录", 1, take(1));
  hall.name = "市政厅";
  /* 样板运行配置：运输队开车（一队一车按队占编，库中备 2 辆周转）、矿井卫星区一座卫星仓
     （矿堆容 +80、集中短驳）——载具与分布式仓储两个机制在完全体里可见 */
  haul.settings["载具"] = "手推车";
  const engOrg = Object.values(S.orgs).find(x => x.template === "工程队");
  if (engOrg) engOrg.settings["自动扩建"] = "开";   // 样板展示自动化闭环：仓库近满自动排队新仓
  S.res["手推车"] += 2;
  S.buildings["仓库"].push({ interior: {}, org: "" });
  S.citySat.push({ b: "仓库", inst: S.buildings["仓库"].length - 1 });
  /* 样板点名补艺：随机出生不保证末道手艺岗有人会，补齐让样板满转 */
  for (const [tpl, art] of [["锯木坊", "木工"], ["锻造坊", "锻造"], ["药剂坊", "制药"], ["木器坊", "木工"], ["冶炼坊", "冶炼"], ["科研院", "识字"]]) {
    const o = Object.values(S.orgs).find(x => x.template === tpl);
    if (o && !membersHave(o, art)) {
      const pid = Object.values(o.slots).flatMap(s => s.persons)[0];
      if (pid) person(pid).skills.push(art);
    }
  }
  feed("已载入完全体样板（聚落→市政厅，全建筑满编运转）");
  S.snap = collectSnap();   // 开局总览快照（此后按情报链更新周期刷新）
}


/* ── 工具 ── */
function mulberry32(a) {   // 轻量确定性 PRNG：同 seed 同布局（复现用）
  return function () {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
export const CIRC = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"];   // 建筑实例枚举（区分座，非命名）
export const circ = i => CIRC[i] ?? String(i + 1);   // 第 10 座起退化为数字（实测 30 座民居时 ①~⑨ 溢出显 undefined）
export const person = pid => S.people.find(p => p.id === pid);
export const idle = () => S.people.filter(p => !p.org);
/* 矿井卫星区：可在矿洞处建的分布式仓库——矿堆容 +80/座，且集中整批短驳（无仓则从矿口远背主城）；
   采矿队·支护架坑木拓宽堆场（+20/人） */
export const satWarehouses = () => (S.citySat || []).filter(e => e.b === "仓库").length;
export function mineBufCap() {
  let sup = 0;
  for (const o of Object.values(S.orgs)) sup += o.slots["支护"]?.persons.length || 0;
  return 40 + 80 * satWarehouses() + 20 * sup;
}

/* 城市布局：一整排，市政厅居中，向左/右两侧扩建；每型建筑占格宽（ CITY_W） */
export const CITY_W = { "市政厅": 16, "仓库": 8, "民居": 4, "伐木小屋": 4, "锯木坊": 8, "锻造坊": 8,
  "药剂坊": 8, "木工房": 8, "冶炼坊": 8, "训练场": 8, "兵营": 8, "办公楼": 8, "书院": 8 };
export function cityCells() {   // 从左到右的格子内容：{b,inst} 或 null 空地
  const out = [];
  for (const e of [...S.cityL].reverse()) for (let i = 0; i < (CITY_W[e.b] || 2); i++) out.push(e);
  for (let i = 0; i < (CITY_W["市政厅"] || 4); i++) out.push({ b: "市政厅", inst: 0 });
  for (const e of S.cityR || []) for (let i = 0; i < (CITY_W[e.b] || 2); i++) out.push(e);
  return out;
}

/* 居住位：基准 4 位，床铺 +4（翻倍），再按层数倍乘（木质上限 2 层） */
export function housingCap() {
  // 住房容量由床位决定（建筑总账 6.6 创始人口径）：基准 4 位，装床铺翻倍；楼层×层数（03 §二 木质上限2层）
  let n = 0;
  for (const inst of (S.buildings["民居"] || []))
    n += (4 + (inst.interior["床铺"] ? 4 : 0)) * (inst.storeys || 1);
  return n;
}
/* ── 拉动制物流（裁决34）：产出默认堆产地空地，搬运工只按「仓库收货政策」回运——
   收货开关 S.intake（三种基础原料，默认全关：要什么自己开）；仓库分类：每座可限定收货类型，
   某类容量＝收该类的仓库座数 × 单座容量（各类独立，不再一满全堵） ── */
export const catLabel = c => RES_CATS.find(x => x[0] === c)?.[1] || c;
export function capOfCat(c) {
  const lab = catLabel(c);
  let n = 0;
  for (const inst of S.buildings["仓库"] || [])
    if (!inst.accepts || inst.accepts === "全部" || inst.accepts === lab) n++;
  return S.knobs.cap * Math.max(n, 1);
}
export const catTotal = c => RES.filter(r => RES_INFO[r].cat === c).reduce((a, r) => a + (S.res[r] || 0), 0);
export const catRoom = c => Math.max(0, capOfCat(c) - catTotal(c));
export const capTotal = () => ["basic", "mat", "prod"].reduce((a, c) => a + capOfCat(c), 0);
/* 一站式总览＝把各处文书运回市政厅的汇总快照：信息量不随情报规模 gate——各组织
   面板的数据由它们自己的信息位收集；情报组织规模只决定更新效率（文书要真的有人拿回来）。
   汇总在编才有总览更新；采编每人把周期缩短（12时基础，每+1人-3时，采编满编4人=下限1时）；无人=停更 */
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
  const g = t => Object.values(S.orgs).filter(x => x.template === t).reduce((a, x) => a + m(x), 0);   // 同型多株（总坊下辖）合计在编
  return {
    at: S.hours,
    res: { ...S.res }, rates: { ...S.rates }, buf: { ...S.buf },
    queue: S.buildOrders.map(o => ({ label: o.kind === "shell" ? o.b + "·新座" : o.b + "·" + o.item,
      pct: Math.round(100 * o.done / (o.vol || o.work || 1)) })),
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
/* ── 个体层（17 号五属性 0~10 + 04 号会/不会技能）：出生分布为 sim 占位（17 号[待定]口径），
   出生流按 seed 确定性推导——同 seed 同一批人；fixed 供开局角色/样板点名 ── */
export const ARTS = ["木工", "锻造", "制药", "冶炼", "识字"];   // 技能＝手艺与识字；采集三线/搬运/施工是基础行为人人可为（裁决46），个体差异走属性
const ART_RATE = { "木工": .25, "锻造": .25, "制药": .2, "冶炼": .2, "识字": .15 };
/* 移民（裁决31：人口增长＝移民吸引，新生儿不做）：外来成年匠人概率更高、属性 3~9 */
const ART_RATE_MIG = { "木工": .35, "锻造": .35, "制药": .25, "冶炼": .25, "识字": .2 };
export function addPersonRaw(name, fixed) {
  S.seq.p += 1;
  const r = mulberry32(((S.seed || 1) * 7919 + S.seq.p * 104729) | 0);
  const roll = () => 2 + Math.floor(r() * 7);   // 2~8（出生分布占位：偏低起、可训练至上限）
  const attr = fixed?.attr || { str: roll(), int: roll(), agi: roll(), cft: roll(), cmd: roll() };
  const skills = fixed?.skills ?? ARTS.filter(a => r() < (ART_RATE[a] || .2));
  S.people.push({ id: "p" + String(S.seq.p).padStart(2, "0"), name, org: "", attr, skills });
}
/* 移民入住：成年档案（属性 3~9、匠艺概率高于本地出生）——城里活多、有床位有口粮才来投 */
export function addImmigrant() {
  S.seq.p += 1;
  const r = mulberry32(((S.seed || 1) * 7919 + S.seq.p * 104729) | 0);
  const roll = () => 3 + Math.floor(r() * 7);
  const skills = ARTS.filter(a => r() < (ART_RATE_MIG[a] || .2));
  S.people.push({ id: "p" + String(S.seq.p).padStart(2, "0"), name: "村民", org: "",
                  attr: { str: roll(), int: roll(), agi: roll(), cft: roll(), cmd: roll() }, skills });
}
export const membersHave = (o, art) => Object.values(o.slots).some(sl =>
  sl.persons.some(pid => person(pid)?.skills.includes(art)));
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
  if (kind !== "hall") {
    for (const def of (tpl.slots || [])) {   // 同名下辖槽（总坊的 厂坊×3）键去重：首槽原名、后续加序号
      let k = def.fn, i = 2;
      while (org.slots[k]) k = def.fn + i++;
      org.slots[k] = { def, persons: [], institution: "" };
    }
    if (!tpl.lead && !org.slots["总管"]) {   // 无显式 lead 岗的模板：首槽即士官长（裁决50）
      const first = Object.keys(org.slots)[0];
      if (first) org.slots[first].def = { ...org.slots[first].def, lead: true };
    }
  }
  if (org.bldgType) {   // 自动进驻一座空置同类建筑；没有则空挂（基础运转受限，工厂工序全停摆）
    const idx = (S.buildings[org.bldgType] || []).findIndex(inst => !inst.org);
    if (idx >= 0) { S.buildings[org.bldgType][idx].org = id; org.bldg = { b: org.bldgType, idx }; }
  }
  S.order.push(id);
  return org;
}
export function feed(text, cls) {
  S.feed.push({ t: S.hours, text, cls: cls || "" });
  if (S.feed.length > 400) S.feed.shift();   // 环形缓冲（160 时长跑试玩的计数器会失明）
}
export function membersOf(o) {
  let n = 0; for (const s of Object.values(o.slots)) n += s.persons.length; return n;
}
/* 个体属性系数（17 号域，占位带宽 ±20%）：采集/搬运吃 str、工序吃 cft——力大气粗/手巧活细的物理差异 */
const attrAvg = (pids, key) => {
  const ps = pids.map(pid => person(pid)).filter(Boolean);
  return ps.length ? ps.reduce((a, p) => a + (p.attr?.[key] ?? 5), 0) / ps.length : 5;
};
const attrMult = (pids, key) => 0.7 + 0.06 * attrAvg(pids, key);   // 均值5=1.0、2=0.82、8=1.18
/* 厂内半成品清单（各厂 WIP 汇总，仓库页「厂内」标签用） */
export function wipList() {
  const rows = [];
  for (const o of S.order.map(x => S.orgs[x]).filter(Boolean))
    for (const [item, qty] of Object.entries(S.wip[o.id] || {}))
      if (qty > 0.001) rows.push({ org: o.name, item, qty });
  return rows;
}
/* 页签解锁门槛（裁决43）：除组织页外，各页要对应槽位在编才解锁——信息有主人，不是 UI 免费送的
   建筑←生产槽（建造线归生产辖）/仓库←运输槽/总览←情报槽；槽有人或下辖机构在编都算（机构入驻即履职） */
export function tabUnlocked(id) {
  if (id === "org") return true;
  const hall = S.orgs.o01;
  if (!hall) return true;
  const subTreeHas = orgId => {   // 整棵子树任一在编（放机构＝放人：效果由人提供，空机构不算——裁决49）
    const o = S.orgs[orgId];
    if (!o) return false;
    if (Object.values(o.slots).some(sl => sl.persons.length)) return true;
    return Object.values(o.slots).some(sl => sl.institution && subTreeHas(sl.institution));
  };
  if (id === "city")   // 建筑页＝建造线：任一「建造」槽在编（裁决43修正）
    return Object.values(S.orgs).some(o => {
      const sl = o.slots["建造"];
      return sl && (sl.persons.length > 0 || (sl.institution && subTreeHas(sl.institution)));
    });
  const key = { wh: "运输", ov: "情报" }[id];
  if (!key) return true;
  const sl = hall.slots[key];
  return !!sl && (sl.persons.length > 0 || (sl.institution && subTreeHas(sl.institution)));
}
/* 设计岗在编（裁决43）：工程队·设计——在编才能看各建筑内部结构预览 */
export const hasDesigner = () => Object.values(S.orgs).some(o => (o.slots["大匠"]?.persons.length || 0) > 0);   // 掌墨师即设计师（裁决52）

/* 在岗施工人力＝各工种作队（工程队·木匠/茅匠/小工槽直派+入驻作队全员；库务所同款口径） */
export function crewCounts() { const c = collectCrews(); return { 木匠: c.木匠.length, 瓦匠: c.瓦匠.length, 小工: c.小工.length }; }
/* 工种采集（裁决52）：工程队·木作/泥瓦/小工 槽——直派人员计该工种；匠班入驻则班组长与匠人计本工种、
   配属小工计小工（放人=放机构同一效果，效果由人提供） */
const TRADE_OF_SLOT = { 木作: "木匠", 泥瓦: "瓦匠", 小工: "小工" };
function collectCrews() {
  const crews = { 木匠: [], 瓦匠: [], 小工: [] };
  for (const o of Object.values(S.orgs))
    for (const [fn, sl] of Object.entries(o.slots)) {
      const trade = TRADE_OF_SLOT[fn];
      if (!trade) continue;
      crews[trade].push(...sl.persons);
      const sub = sl.institution && S.orgs[sl.institution];
      if (sub) for (const [sfn, s2] of Object.entries(sub.slots))
        (sfn === "小工" ? crews.小工 : crews[trade]).push(...s2.persons);
    }
  return crews;
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

/* ── 库存目标（按需生产）：锯木坊按出材偏好盯主产物，其余坊盯末道产物 ── */
function targetResOf(o) {
  if (o.template === "锯木坊") return o.settings["出材偏好"] === "优先木材" ? "木材" : "木板";
  const st = [...(o.steps || [])].reverse().find(s => s.outCity);
  return st ? Object.keys(st.outCity)[0] : null;
}
export function targetOf(o) {
  const v = o.settings["库存目标"];
  return !v || v === "不限" ? Infinity : Number(v.slice(1));
}
export function targetHit(o) {
  const r = targetResOf(o);
  return !!r && S.res[r] >= targetOf(o);
}
/* 停摆原因（自动化审计：停摆不可视）——工厂 缺设备/缺原料/达标歇线/未驻建筑；采集队 卫星堆满停采 */
export function stallInfo(o) {
  if (o.steps && o.steps.length) {
    if (!membersOf(o)) return "";
    if (!o.bldg) return "未驻建筑——工序停摆";
    if (targetHit(o)) return "库存达标·歇线";
    if (o.steps.every(st => !orgEquip(o, st.equip))) return "缺设备——工序停摆";
    /* 与 advance 的 runnable 同构：手艺门槛 + 厂内堆位 + 原料，全停才亮灯（部分停=半速运转） */
    const canRun = o.steps.some(st => orgEquip(o, st.equip)
      && !(st.art && !membersHave(o, st.art))
      && !(st.wip && (wipOf(o)[st.wip] || 0) >= 20)
      && (st.inCity
        ? Object.entries(st.inCity).every(([r, n]) => S.res[r] >= 0.001)
        : ((wipOf(o)[st.wipIn] || 0) > 0.001 || !!st.altCity && Object.entries(st.altCity).every(([r, n]) => S.res[r] >= 0.001))));
    if (canRun) return "";
    const noArt = [...new Set(o.steps.filter(st => st.art && !membersHave(o, st.art)).map(st => st.art))];
    if (noArt.length) return `缺手艺：无人在编会${noArt.join("/")}——训练营练人或等对口新生儿`;
    return "缺原料——工序停摆";
  }
  for (const slot of Object.values(o.slots))
    if (slot.def.terrain && TERRAIN[slot.def.terrain].satellite
        && S.buf[bufKey(slot.def.terrain, slotProduct(slot))] >= mineBufCap())
      return "卫星堆满·停采";
  return "";
}
/* ── 施工计划（工序链实例化）：环节定额 × 体量（units＝CITY_W/8，民居0.5/设施1/市政厅2）；
   形制决定环节集合（棚=开敞/屋=围木/架=梁柱换料），再叠建筑级 patch；
   软装＝单环节「安装」（杂活）；民居加层＝「接层立架→上层墙顶」两环节（木匠活） ── */
export function planOf(kind, b, item, storeys = 1) {
  if (kind === "interior") {
    const it = BUILDINGS[b].interior.find(x => x.item === item);
    return [{ id: "安装", name: "安装", trade: "小工", vol: it.work, cost: { ...it.cost }, deps: [] }];
  }
  if (kind === "floor") {
    const u = (CITY_W[b] || 8) / 8;
    const sc = n => Math.max(1, Math.round(n * u));
    const d = BUILDINGS[b];
    const roof = { cost: d.form === "架" ? { "木瓦": sc(2) } : { "茅草": sc(2) }, trade: d.form === "架" ? "木匠" : "茅匠" };
    // 加层环节＝调研实证（拆顶期房屋无顶——顶层暴露，风险事件可后续挂）：拆顶→接柱→楼板→上层墙→楼梯→新顶
    return [
      { id: "拆旧顶", name: "拆旧顶", trade: "小工", vol: sc(2), cost: {}, deps: [] },
      { id: "接柱立架", name: "接柱立架", trade: "木匠", vol: sc(3), cost: { "原木": sc(2), "木梁": sc(1) }, deps: ["拆旧顶"] },
      { id: "架楼板", name: "架楼板", trade: "木匠", vol: sc(2), cost: { "木梁": sc(1), "木板": sc(2) }, deps: ["接柱立架"] },
      { id: "上层墙", name: "上层墙", trade: "木匠", vol: sc(3),
        cost: d.form === "架" ? { "木板": sc(2) } : { "原木": sc(2) }, deps: ["架楼板"] },
      { id: "楼梯", name: "楼梯", trade: "木匠", vol: sc(2), cost: { "木板": sc(1) }, deps: ["架楼板"] },
      { id: "盖新顶", name: "盖新顶", trade: roof.trade, vol: sc(3), cost: roof.cost, deps: ["上层墙", "楼梯"] },
    ];
  }
  const d = BUILDINGS[b];
  const u = (CITY_W[b] || 8) / 8;
  const sc = n => Math.max(1, Math.round(n * u));   // 体量折算（料至少 1）
  return FORM_PHASES[d.form].map(id => {
    let ph = { ...PHASE_LIB[id] };
    if (d.form === "架" && PHASE_LIB_FRAMED[id]) ph = { ...ph, ...PHASE_LIB_FRAMED[id] };
    if (d.patch && d.patch[id]) ph = { ...ph, ...d.patch[id] };
    return { id, name: ph.name || id, trade: ph.trade,
      vol: Math.max(1, Math.round(ph.vol * u)),
      cost: Object.fromEntries(Object.entries(ph.cost).map(([r, n]) => [r, sc(n)])),
      deps: PHASE_DEPS[id].filter(x => FORM_PHASES[d.form].includes(x)) };
  });
}
/* 计划合计（预检/自动扩建用）：料单汇总 + 总工作量（时长＝工作量÷作队出力，是涌现值） */
export function planTotal(phases) {
  const cost = {};
  let vol = 0;
  for (const p of phases) { vol += p.vol; for (const [r, n] of Object.entries(p.cost)) cost[r] = (cost[r] || 0) + n; }
  return { cost, vol };
}
/* 兼容旧名（自动扩建沿用）：shellBill＝硬装计划合计 */
export function shellBill(b) { return planTotal(planOf("shell", b)); }
/* 施工前置/资源校验——单一真相源：按钮禁用态与 queueBuild 同一规则（审计：校验双轨会漂移）。
   资源预检＝工序链全额可付（开工后逐环节扣料，料不齐的环节等料停摆） */
export function buildBlocked(kind, b, item, idx, storeys = 1) {
  const d = BUILDINGS[b];
  if (kind === "interior") {
    const inst = S.buildings[b]?.[idx];
    if (!inst) return `${b} 第${idx + 1}座尚不存在`;
    if (inst.interior[item]) return "已装";
    if (S.buildOrders.some(o => o.b === b && o.item === item && o.idx === idx)) return "已在施工队列";
    const w = d.interior.find(x => x.item === item)?.w || 1;
    if (interiorUsed(b, idx) + w > interiorCap(b, S.buildings[b][idx].storeys || 1))
      return `室内格已满（${interiorCap(b, S.buildings[b][idx].storeys || 1)} 格）——加层或另建一座`;
  }
  if (kind === "floor") {
    const inst = S.buildings[b]?.[idx];
    if (!inst) return `${b} 第${idx + 1}座尚不存在`;
    if ((inst.storeys || 1) >= (d.floors || 3)) return `本形制上限 ${d.floors || 3} 层（材质定层：茅草棚1/木板房3——石砖档随石砖经济开）`;
    if (S.buildOrders.some(o => o.kind === "floor" && o.b === b && o.idx === idx)) return "已在施工队列";
  }
  const cost = planTotal(planOf(kind, b, item || undefined)).cost;
  return canPay(cost) ? "" : "资源不足：" + costStr(cost);
}
/* 撤单：未开工环节全额返料（料还没扣），已开工环节的料已砌进结构不返、工时全沉没
   （较裁决26的整单全额返料按工序口径收窄——工地备料只退没用的） */
export function cancelBuild(i) {
  const o = S.buildOrders[i]; if (!o) return;
  let back = 0;
  if (o.phases) for (const ph of o.phases) if (!ph.paid)
    for (const [r, n] of Object.entries(ph.cost)) { S.res[r] += n; back += n; }
  const tag = o.kind === "shell" ? "·新座" : o.kind === "floor" ? "·加层" : "·" + o.item;
  S.buildOrders.splice(i, 1);
  feed(`撤单 ${o.b}${tag}，未开工环节返料 ${back} 件（已开工的料已砌进结构、工时沉没）`, "warn");
}
/* 拆卸软装：全额返料——库满缺料时的腾挪出口（拆掉设备=所驻厂该工序停摆，物理因果） */
export function dismantle(b, idx, item) {
  const inst = S.buildings[b]?.[idx];
  if (!inst?.interior[item]) return;
  delete inst.interior[item];
  const it = BUILDINGS[b].interior.find(x => x.item === item);
  for (const [r, n] of Object.entries(it.cost)) S.res[r] += n;
  feed(`拆卸 ${b}${circ(idx)}·${item}，返料 ${costStr(it.cost)}`, "warn");
}
/* ── 室内布局（03 §4.3 默认自动布局：逐层从左到右贪心）——每层格数＝CITY_W×2，物品按目录序占 w 格；
   手动摆位/编辑模式归正片，sim 先落自动布局与容量约束 ── */
export const interiorCap = (b, storeys = 1) => (CITY_W[b] || 4) * 2 * storeys;
export function interiorUsed(b, idx) {
  const inst = S.buildings[b]?.[idx]; if (!inst) return 0;
  let w = 0;
  for (const it of BUILDINGS[b].interior || [])
    if (inst.interior[it.item]) w += it.w || 1;
  for (const o of S.buildOrders)   // 在途安装单同样占格（防超卖）
    if (o.kind === "interior" && o.b === b && o.idx === idx)
      w += BUILDINGS[b].interior.find(x => x.item === o.item)?.w || 1;
  return w;
}
export function interiorLayout(b, idx) {
  const inst = S.buildings[b]?.[idx]; if (!inst) return [];
  const W = (CITY_W[b] || 4) * 2, L = inst.storeys || 1;
  const layers = Array.from({ length: L }, () => []);
  let li = 0;
  for (const it of BUILDINGS[b].interior || []) {
    if (!inst.interior[it.item]) continue;
    const w = it.w || 1;
    const used = () => layers[li].reduce((a, p) => a + p.w, 0);
    if (used() + w > W && li < L - 1) li += 1;   // 本层放不下→上层
    layers[li].push({ item: it.item, w, x: used() });
  }
  return layers;
}
/* 含施工中的完整排布（落成块+待建块）——布局真相源单一化，CityPage 纯渲染 */
export function cityLayout() {
  const runs = [];
  for (const c of cityCells()) {
    const last = runs[runs.length - 1];
    if (last && last.b === c.b && last.inst === c.inst) last.w += 1;
    else runs.push({ b: c.b, inst: c.inst, w: 1 });
  }
  const sh = o => o.kind === "shell";
  return { blocks: runs,
    pendL: S.buildOrders.filter(o => sh(o) && o.side === "左").reverse(),
    pendR: S.buildOrders.filter(o => sh(o) && o.side !== "左" && o.side !== "矿卫"),
    pendSat: S.buildOrders.filter(o => sh(o) && o.side === "矿卫") };
}
/* ── 存档（localStorage）：一局核心字段——刷新/关页不丢城；重开按钮清档 ── */
const SAVE_FIELDS = ["hours", "seq", "people", "orgs", "res", "buf", "wip", "buildings",
                     "buildOrders", "orgTasks", "cityL", "cityR", "citySat", "mobilized", "seed", "knobs", "popCd", "autoCd", "order", "wear", "intake"];
export function saveState() {
  const data = {}; for (const k of SAVE_FIELDS) data[k] = S[k];
  try { localStorage.setItem("orgsim.save", JSON.stringify(data)); } catch {}
}
export function hasSave() { try { return !!localStorage.getItem("orgsim.save"); } catch { return false; } }
export function clearSave() { try { localStorage.removeItem("orgsim.save"); } catch {} }
export function loadState() {
  try {
    const data = JSON.parse(localStorage.getItem("orgsim.save") || "null");
    if (!data || !data.orgs) return false;
    Object.assign(S, data, { sel: null, selSlot: null, feed: [], snap: null, rates: {}, borrows: {}, speed: 0 });
    if (!data.intake) S.intake = { "原木": true, "铁矿": true, "农作物": true };   // 旧档（裁决34 前）无收货政策=按旧口径全收，别把老城饿死——判 data 而非 S（S 被 reset 预填恒真，迁移曾永不触发）
    for (const r of RES) if (S.res[r] === undefined) S.res[r] = 0;   // 目录扩容（门扇/窗扇等）：旧档补零键
    for (const o of Object.values(S.orgs).filter(x => x.template === "工程队")) {   // 工程队双层化迁移（裁决52）：旧槽人员归位
      const moveTo = { 测量: "大匠", 设计: "大匠", 质检: "监工", 木匠: "木作", 茅匠: "泥瓦" };
      for (const [ofn, nfn] of Object.entries(moveTo)) {
        const sl = o.slots[ofn];
        if (!sl) continue;
        if (sl.persons.length) {
          if (!o.slots[nfn]) o.slots[nfn] = { def: { fn: nfn, n: 4, homog: true, pos: "gain", role: "迁移归位" }, persons: [], institution: "" };
          o.slots[nfn].persons.push(...sl.persons);
        }
        delete o.slots[ofn];
      }
    }
    for (const crew of ["木匠队", "茅匠队", "小工队"]) {   // 作队解散迁移（裁决51）：人员并入宿主工程队工种槽
      for (const o of Object.values(S.orgs).filter(x => x.template === crew)) {
        const hostSlot = Object.values(S.orgs).flatMap(h => Object.values(h.slots))
          .find(sl => sl.institution === o.id);
        if (hostSlot) {
          const trade = crew === "木匠队" ? "木匠" : crew === "茅匠队" ? "茅匠" : "小工";
          const host = Object.values(S.orgs).find(h => h.slots[trade] && Object.values(h.slots).some(sl => sl.institution === o.id));
          if (host) for (const sl of Object.values(o.slots))
            for (const pid of sl.persons) { host.slots[trade].persons.push(pid); person(pid).org = host.id; }
          hostSlot.institution = "";
        }
        delOrg(o.id);
      }
    }
    for (const o of Object.values(S.orgs)) {   // 士官式主管迁移（裁决50）：旧档独立主管槽的人员并入 lead 岗
      const sup = o.slots["主管"];
      if (sup && sup.persons.length) {
        const lead = Object.values(o.slots).find(sl => sl.def.lead) || Object.values(o.slots)[0];
        if (lead && lead !== sup) lead.persons.push(...sup.persons);
      }
      if (sup) delete o.slots["主管"];
    }
    for (const ord of S.buildOrders || [])   // 旧档施工单（工序链模型前）迁移：余量折成已付费单环节（旧模型整单预付过）
      if (!ord.phases) ord.phases = [{ id: "余量", name: "余量施工", trade: "木工",
        vol: Math.max(1, (ord.vol || ord.work) - ord.done), done: 0, paid: true, cost: {}, deps: [], waiting: false }];
    for (const o of Object.values(S.orgs)) {   // 回链模板定义：存档 def 是旧快照，重指 ORGS 现行定义防版本漂移
      const tpl = ORGS[o.template] || {};
      for (const sl of Object.values(o.slots)) {
        const d = (tpl.slots || []).find(x => x.fn === sl.def.fn);
        if (d) sl.def = d;
      }
      o.steps = tpl.steps || o.steps || [];
    }
    S.snap = collectSnap();
    return true;
  } catch { return false; }
}

/* ═════════ 经济推进 ═════════ */
export function advance(dt) {
  S.hours += dt;   // 时钟随推进走（曾只由 App 节拍累加——__sim.advance 直驱时快照停更/时间戳全 0，两口径必须同一真相）
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
      if (d.terrain === "矿洞" && (o.slots["提升"]?.persons.length || 0) > 0) rate *= 1.25;   // 坑口吊运
      const amt = rate * attrMult(slot.persons, "str") * w * mult * dt;   // 力气影响采集
      if (d.terrain === "耕地") S.buf[bufKey("耕地", "茅草")] = (S.buf[bufKey("耕地", "茅草")] || 0) + amt * 0.5;   // 收割副产：麦秆同堆待运
      // 三线产出都进场地堆、都要搬运工搬回主仓；差异只在堆容与运距：
      // 树林/耕地＝主城侧产地，堆不设上限（无停采）；矿洞＝卫星城，堆容 40+80×卫星仓
      const prod2 = slotProduct(slot);
      const key = bufKey(d.terrain, prod2);
      const cap2 = TERRAIN[d.terrain].satellite ? mineBufCap() : Infinity;
      const got = Math.min(amt, Math.max(0, cap2 - S.buf[key]));
      S.buf[key] += got; flow[prod2] += got;
    }
  }
  // ②′ 生产局·采集兜底：无专门队时的泛采集（0.4/人时，均摊到仍有余量的缓冲堆）
  const dept = Object.values(S.orgs).find(x => x.template === "生产局");
  const deptGatherers = dept ? (dept.slots["采集"]?.persons.length || 0) : 0;
  if (deptGatherers) {
    const amt = K.deptGather * deptGatherers * mult * dt;
    const keys0 = Object.keys(S.buf);
    if (keys0.length) {   // 散工兜底：均摊进各线场地堆（矿堆满则该线自然截断）
      const per = amt / keys0.length;
      for (const k of keys0) {
        const cap2 = k.startsWith("矿洞") ? mineBufCap() : Infinity;
        const got = Math.min(per, Math.max(0, cap2 - S.buf[k]));
        S.buf[k] += got; flow[k.split("|")[1]] += got;
      }
    }
  }
  // ③ 搬运（库管在岗才运转；被通报场地全速，未通报打折扣）
  let haulers = 0, keeper = false;
  for (const o of Object.values(S.orgs)) {
    const kp = o.slots["库管"];
    if (kp && (kp.persons.length || (kp.institution && S.orgs[kp.institution] && membersOf(S.orgs[kp.institution]) > 0))) keeper = true;   // 机构在编＝其有人在（裁决49：效果由人提供）
    const hp = o.slots["搬运"]; if (hp) haulers += hp.persons.length;
  }
  if (keeper && haulers > 0) {
    let bulkFirst = false, plan = "", dispStaffed = false;
    const haulPids = [];
    /* 载具按队占编（README 挂账：多队可同登一辆）：一队一车、队级独占，库里车不够则后队仍人力；
       曾是任一队开车即给全部队 1.5×——车的提速只落在占到编的队身上 */
    let boosted = 0, cartsLeft = Math.floor(S.res["手推车"] || 0);
    for (const o of Object.values(S.orgs)) if (o.slots["搬运"]) {
      const n = o.slots["搬运"].persons.length;
      if (o.settings["载具"] === "手推车" && n > 0 && cartsLeft >= 1) { cartsLeft -= 1; boosted += n; }
      if (o.settings["装卸规则"] === "大宗优先") bulkFirst = true;
      plan = o.settings["运输计划"] || "";
      dispStaffed = (o.slots["调度"]?.persons.length || 0) > 0;   // 排单是调度的活：调度在岗才生效
      haulPids.push(...o.slots["搬运"].persons);
    }
    const haulStr = attrMult(haulPids, "str");   // 力气影响搬运
    const wOf = k => dispStaffed && plan.indexOf(k.split("|")[1]) >= 0 ? 2 : 1;   // 运输计划：被偏重线运力×2
    // 运距逐线折算（物理）：矿堆（卫星城）无仓 ×0.6 远背、有卫星仓 ×1 集中短驳；主城侧线 ×1 城内短驳
    const distOf = k => k.startsWith("矿洞") ? (satWarehouses() > 0 ? 1 : 0.6) : 1;
    const keys = Object.keys(S.buf).filter(key2 => S.buf[key2] > 0.001 && S.intake[key2.split("|")[1]] !== false);   // 拉动制：收货政策没开的线不回运，继续堆产地空地
    // 运力按堆量加权分配（各线运距已含在自身运力里）；装卸规则保留：
    // 均匀分运=按堆量比例；大宗优先=先清最大堆
    const wSum = keys.reduce((a, k) => a + S.buf[k] * wOf(k) / distOf(k), 0);
    let move = Math.min(K.haul * haulStr * (boosted * 1.5 + haulers - boosted) * mult * dt, keys.reduce((a, k) => a + S.buf[k], 0));
    if (move > 0 && wSum > 0) {
      const order = bulkFirst ? [...keys].sort((a, b) => S.buf[b] - S.buf[a]) : keys;
      let remaining = move;
      for (const key2 of order) {
        const disc = notified[key2] === false ? K.uninfo : 1;
        const share = bulkFirst ? Math.min(remaining, S.buf[key2])
                                : move * (S.buf[key2] * wOf(key2) / distOf(key2)) / wSum;
        const room = catRoom(RES_INFO[key2.split("|")[1]].cat);   // 分类容量独立：基础原料类满只停该类，不堵别的
        const m = Math.min(share * disc, S.buf[key2], room);
        if (bulkFirst) remaining -= m;
        S.buf[key2] -= m;
        S.res[key2.split("|")[1]] += m;
      }
    }
    if (boosted > 0 && move > 0) {   // 载具磨损（物理 sink：车是会用坏的）——每 240 搬运人时折损一辆，木器坊从此有持续需求（只计占编到车的搬运工）
      S.wear.cart += dt * boosted;
      while (S.wear.cart >= 240) {
        S.wear.cart -= 240;
        if (S.res["手推车"] >= 1) { S.res["手推车"] -= 1; flow["手推车"] -= 1; feed("一辆手推车损耗报废（木器坊可再产）", "warn"); }
      }
    }
  }
  // ④ 工厂：每槽一道工序、每工序需设备；工时在可开工工序间均摊——一人厂=独轮回全工序（慢但转）
  for (const o of Object.values(S.orgs)) {
    const steps = o.steps || [];
    if (!steps.length) continue;
    const workers = membersOf(o);
    if (!workers) continue;
    if (targetHit(o)) continue;   // 库存目标：产物达标即整坊歇线（降库存后自动复工）
    const runnable = steps.map(st => {
      if (!orgEquip(o, st.equip)) return false;
      if (st.art && !membersHave(o, st.art)) return false;   // 末道手艺门槛：细活要会艺者把关（粗工序人人可上，不锁开局）
      if (st.wip && (wipOf(o)[st.wip] || 0) >= 20) return false;   // 厂内堆位 20：下道堵料/设备断链时本道满料停机（试玩实测断链 WIP 曾堆 231——厂内堆场有限是物理事实）
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
    const cftM = attrMult(Object.values(o.slots).flatMap(s => s.persons), "cft");   // 手巧影响工序
    for (let i = 0; i < steps.length; i++) {
      if (!runnable[i]) continue;
      const st = steps[i];
      const slot = o.slots[st.name];
      if (slot && !slot.persons.length) {
        const src = Object.values(o.slots).find(s => s.persons.length);
        if (src) (S.borrows[o.id] ||= []).push({ from: src.def.fn, to: st.name });
      }
      let want = K.craft * cftM * perStepOf(i) * mult * dt;   // 工时按偏好权重分流（无偏好=均摊），手巧加成
      if (st.outCity) {   // 分类库容钳制（实测缺陷：产出曾把仓库塞爆——塞不下就少产，物料不凭空消失）
        const unit = Object.values(st.outCity).reduce((a, b) => a + b, 0);
        const cat = RES_INFO[Object.keys(st.outCity)[0]].cat;
        want = Math.min(want, catRoom(cat) / unit);
      }
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
  // ⑤ 施工（结构工作量制）：作队出力折工作量——时长＝工作量÷出力（涌现值）；
  //    木匠活归木匠（吃 cft）、小工活归小工（吃 str），两队各出各力互不抢人（真并行）；
  //    环节开工即扣料（料不齐＝该环节等料⚠，别环节照跑）；对应作队无人＝该环节停摆（缺人）
  if (S.buildOrders.length) {
    const crews = collectCrews();   // 工种＝人提供：直派匠人/班组入驻皆计（裁决49/52）
    for (const o of Object.values(S.orgs))
      for (const [fn, sl] of Object.entries(o.slots)) {
      }
    if (crews.木匠.length || crews.瓦匠.length || crews.小工.length) {
      const ord = S.buildOrders[0];
      const doneOf = id => { const p = ord.phases.find(x => x.id === id); return !p || p.done >= p.vol; };
      const act = ord.phases.filter(p => p.done < p.vol && p.deps.every(doneOf));
      const byTrade = { 木匠: [], 瓦匠: [], 小工: [] };
      for (const ph of act) {
        if (!ph.paid) {
          if (!canPay(ph.cost)) { ph.waiting = true; continue; }   // 等料停摆：工地常态，别的一切照跑
          pay(ph.cost); ph.paid = true; ph.waiting = false;
        }
        byTrade[ph.trade].push(ph);
      }
      for (const trade of ["木匠", "瓦匠", "小工"]) {
        const list = byTrade[trade];
        for (const ph of list) ph.nostaff = !crews[trade].length;   // 作队无人：环节干瞪眼
        if (!list.length || !crews[trade].length) continue;
        const out = crews[trade].length * attrMult(crews[trade], trade === "小工" ? "str" : "cft")
                    * mult * dt / list.length;   // 该作队出力均分给它名下的在跑环节
        for (const ph of list) ph.done += out;
      }
      ord.done = ord.phases.reduce((a, p) => a + Math.min(p.done, p.vol), 0);
      if (ord.phases.every(p => p.done >= p.vol)) {
        if (ord.kind === "shell") {
          S.buildings[ord.b].push({ interior: {}, org: "", storeys: 1 });
          const idx = S.buildings[ord.b].length - 1;
          // 落成入排：新座进入城市一排（建筑页渲染；单上 side 定翼，未带 side 的单落右翼）
          (ord.side === "矿卫" ? S.citySat : ord.side === "左" ? S.cityL : S.cityR).push({ b: ord.b, inst: idx });
          const waitOrg = Object.values(S.orgs).find(x => x.bldgType === ord.b && !x.bldg);
          if (waitOrg) {   // 组建在建筑之前的空挂组织，落成即自动进驻
            S.buildings[ord.b][idx].org = waitOrg.id;
            waitOrg.bldg = { b: ord.b, idx };
            feed(`${waitOrg.name} 进驻新落成的${ord.b}${circ(idx)}`, "good");
          }
        }
        else if (ord.kind === "floor") {
          const inst = S.buildings[ord.b][ord.idx];
          inst.storeys = (inst.storeys || 1) + 1;   // 木质上限2层由 buildBlocked 钳
          feed(`${ord.b}${circ(ord.idx)} 加层落成——${inst.storeys} 层（居住位与内构格翻倍）`, "good");
        }
        else S.buildings[ord.b][ord.idx].interior[ord.item] = true;
        const tag = ord.kind === "shell" ? `第${S.buildings[ord.b].length}座落成`
          : ord.kind === "floor" ? `${circ(ord.idx)}·加层完成` : `${circ(ord.idx)}·${ord.item}装好`;
        feed(`${ord.b} ${tag}（工程队交付）`, "good");
        S.buildOrders.shift();
      }
    }
  }
  tickOrgTasks(dt);   // 筹建任务读条（裁决48）
  // ⑥′ 自动化：人事局补员 + 工程队自动扩建 + 人口缓增（组织规模越大自动化越高）
  {
    const hr = Object.values(S.orgs).find(x => x.template === "人事局");
    const nHR = hr ? hr.slots["人事"].persons.length : 0;
    if (nHR > 0) {
      S.autoCd = (S.autoCd || 0) + dt;
      if (S.autoCd >= 8 / nHR) {   // 人事在编越多补得越勤
        S.autoCd = 0;
        let pid = S.people.find(x => !x.org)?.id;
        if (!pid) {   // 无闲人：从多人非必须岗匀一人（人事局的调剂职责；保留至少一人不动 must 岗）
          let src = null;
          for (const o of Object.values(S.orgs))
            for (const sl of Object.values(o.slots))
              if (sl.def.pos !== "must" && !sl.institution && sl.persons.length > 1
                  && (!src || sl.persons.length > src.sl.persons.length))
                src = { o, sl };
          if (src) {
            pid = src.sl.persons.pop();
            person(pid).org = "";   // 先置待业，补进目标岗时再挂
            feed(`人事局调剂：${src.o.name}「${src.sl.def.fn}」匀一人补缺`, "good");
          }
        }
        if (pid && !person(pid).org) {
          let target = null;
          const bufSum = () => Object.values(S.buf).reduce((a, b) => a + b, 0);
          /* 采集线饱和（物理判据，非抽象阈值）：卫星堆满＝采了也停；收货没开＝城中无消费入口，
             场地堆已压单人两时产能再加人纯属堆高——两条都不补（搬运饱和见下，同一审计） */
          const gatherSaturated = sl => {
            if (!sl.def.terrain) return false;
            const prod = slotProduct(sl), key = bufKey(sl.def.terrain, prod);
            if (TERRAIN[sl.def.terrain].satellite && (S.buf[key] || 0) >= mineBufCap()) return true;
            return S.intake[prod] === false && (S.buf[key] || 0) >= 2 * K.gather;
          };
          for (const o of Object.values(S.orgs))
            for (const [fn, sl] of Object.entries(o.slots))
              if (sl.def.pos === "must" && !sl.institution && sl.persons.length < slotCap(o, sl)
                  && !(fn === "搬运" && bufSum() < haulers * K.haul * 2)   // 饱和判断：不足两时活不补搬运（审计：HR 曾把过剩人口全灌进空转搬运）
                  && !gatherSaturated(sl)
                  && (!target || sl.persons.length < target.sl.persons.length))
                target = { o, sl, fn };
          if (target) {
            target.sl.persons.push(pid); person(pid).org = target.o.id;
            feed(`人事局补员：${target.o.name}「${target.fn}」补进 ${person(pid).name}`, "good");
          }
        }
      }
    }
    const eng = Object.values(S.orgs).find(x => x.template === "工程队");
    const whBill = shellBill("仓库");
    if (eng && eng.settings["自动扩建"] === "开" && S.buildings["仓库"]?.length
        && resTotal() >= capTotal() * 0.9
        && (!S.buildOrders.length || capTotal() - resTotal() <= 0.05)   // 平时保底不压主线、一次一座；顶格停采＝急救插队（停采余量是渐近小数，须用容差判满）
        && canPay(whBill.cost)) {
      const emergency = S.buildOrders.length > 0;   // 顶格停采=急救：插队到最前（在办建造单让位），平时排尾不压主线
      const phases = planOf("shell", "仓库").map(p => ({ ...p, done: 0, paid: false, waiting: false }));
      S.buildOrders[emergency ? "unshift" : "push"]({ kind: "shell", b: "仓库", item: "", idx: -1,
        side: "右", storeys: 1, vol: whBill.vol, done: 0, phases });   // 逐环节扣料，不再整单预付
      feed(emergency ? "工程队自动扩建·急救插队：仓库顶格，新仓排到最前" : "工程队自动扩建：仓库近满，新一座已排队", "good");
    }
    S.popCd = (S.popCd || 0) + dt;
    if (S.popCd >= 24) {   // 移民吸引（裁决31/33）：有空床即来投——耕地产出只做增益/纤维/药材原料，不作口粮
      S.popCd = 0;
      if (housingCap() > S.people.length) {
        addImmigrant();
        feed("移民入住：城里有余房，外来匠人来投（耕产物不作口粮——只做增益/纤维/药材）", "good");
      }
    }
    /* 流失侧（「有活干有人留」的另一半）：村民闲置满 72 时（三天）离乡谋生——
       在编者闲置钟清零；开局角色（你/动员官）不离。进城门是空床，离城门是没活干 */
    for (const p of [...S.people]) {
      if (p.org) { p.idleT = 0; continue; }
      p.idleT = (p.idleT || 0) + dt;
      if (p.name === "村民" && p.idleT >= 72) {
        S.people.splice(S.people.indexOf(p), 1);
        feed(`离乡谋生：闲置三天没活干，一名村民出城去了（有活干有人留）`, "warn");
      }
    }
    /* 常备兵操练军械磨损（物理 sink）：每 150 时需换装 1 剑——军需岗在编才办领用（无人/无剑＝登记警告，不叠加惩罚） */
    const army = Object.values(S.orgs).find(x => x.template === "常备军");
    if (army && army.settings["兵役制度"] === "常备兵役" && membersOf(army) > 0) {
      S.wear.sword += dt;
      if (S.wear.sword >= 150) {
        S.wear.sword -= 150;
        const qua = (army.slots["军需"]?.persons.length || 0) > 0;
        if (qua && S.res["铁剑"] >= 1) { S.res["铁剑"] -= 1; feed("常备军军械换装：领铁剑×1（军需岗呈报）", "warn"); }
        else feed(qua ? "军械待换：库中铁剑不足——锻造坊该开工了" : "军械磨损待换：军需岗无人，领用没人办", "bad");
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
  // ⑥ 训练推进（04 §三 组织对组织 + 17 §二 落到个体）：100 点内部进度一结业；
  //    目标=属性+1（钳 0~10）或全员习得技能（目标技能教官须会——不会的教不了）；
  //    无教官停摆进度保留；受训组织/训练营解散即取消
  for (const camp of Object.values(S.orgs)) {
    if (camp.template !== "训练营") continue;
    const trainee = camp.settings["受训组织"] ? S.orgs[camp.settings["受训组织"]] : null;
    if (!trainee) continue;
    const n = camp.slots["教官"]?.persons.length || 0;
    if (!n) continue;   // 无教官=停摆（进度保留）
    const goal = camp.settings["训练目标"] || "属性·cft";
    const isArt = goal.startsWith("技能·");
    const key = goal.slice(3);
    if (isArt && !camp.slots["教官"].persons.some(pid => person(pid)?.skills.includes(key))) continue;
    trainee.trainProg += 4 * n * attrMult(camp.slots["教官"].persons, "cmd")
      * attrMult(Object.values(trainee.slots).flatMap(s => s.persons), "int") * mult * dt;   // 教官 cmd 带兵（17 号修正域）× 受训在编 int（17 §23 学习快慢吃 int——明文消费端）
    if (trainee.trainProg >= 100 - 1e-6) {   // 浮点累加边界
      trainee.trainProg = 0;
      trainee.trainLv += 1;
      const ids = Object.values(trainee.slots).flatMap(s => s.persons);
      if (isArt) {
        for (const pid of ids) { const p = person(pid); if (p && !p.skills.includes(key)) p.skills.push(key); }
        feed(`${trainee.name} 全员习得「${key}」（${camp.name} 教官呈报）`, "good");
      } else {
        let up = 0;
        for (const pid of ids) { const p = person(pid); if (p && p.attr[key] < 10) { p.attr[key] += 1; up++; } }
        feed(up ? `${trainee.name} 集训结业：${up} 人 ${key}+1（${camp.name} 教官呈报）`
                : `${trainee.name} ${key} 已全员满级——换个训练目标`, up ? "good" : "warn");
      }
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
export function createOrgAt(containerId, fn, name) {   // 即时构筑（程序路径）；玩家路径＝startOrgTask 筹建读条（裁决48）
  const container = S.orgs[containerId];
  if (!container || !container.slots[fn]) return;
  const slot = container.slots[fn];
  /* 先放人后构筑（裁决47）：槽得先有人在编——首位在编者构筑后自动转任新组织主管，余者回待业 */
  if (slot.institution) { feed(`${container.name}「${fn}」槽已有机构`, "bad"); return; }
  if (!slot.persons.length) { feed(`「${fn}」槽需先放人——放完人才可以构筑组织（在编者将转任主管）`, "bad"); return; }
  const movers = slot.persons;
  const cost = LATE_COST[name] || {};
  if (cost.prereqSkill) { const why = createBlocked(name); if (why) { feed(why, "bad"); return; } }   // 前提通过则放行（曾无条件 return——科研院永远建不成）
  if (cost.res && !canPay(cost.res)) { feed(`构筑「${name}」资源不足（${costStr(cost.cost || cost.res)}）`, "bad"); return; }
  if (cost.res) pay(cost.res);
  const o = addOrgRaw(name, 2, "");
  slot.persons = [];
  slot.institution = o.id;
  const head = movers.shift();
  const leadSlot = Object.values(o.slots).find(sl => sl.def.lead) || Object.values(o.slots)[0];
  if (head && leadSlot) {
    leadSlot.persons.push(head); person(head).org = o.id;
    feed(`${person(head)?.name} 转任 ${o.name}${leadSlot.def.fn}${o.template.endsWith("队") ? "长" : ""}（士官式主管：自己也干活，裁决50）`, "good");
  }
  for (const pid of movers) person(pid).org = "";   // 槽内其余人回待业（主管只取首位）
  feed(`构筑 ${o.name}，入驻 ${container.name}「${fn}」槽`, "good");
  if (o.bldgType)
    feed(o.bldg
      ? `${o.name} 驻${o.bldg.b}${CIRC[o.bldg.idx]}`
      : `${o.name} 无${o.bldgType}可驻——基础运转受限，先再建一座`, o.bldg ? "good" : "bad");
  S.sel = o.id; S.selSlot = null;
}
export function queueBuild(kind, b, item, idx, side = "右", storeys = 1) {
  const why = buildBlocked(kind, b, item, idx, storeys);   // 校验单一真相源（按钮禁用态同源）
  if (why) { feed(`${b}：${why}`, "bad"); return; }
  const phases = planOf(kind, b, item || undefined).map(p => ({ ...p, done: 0, paid: false, waiting: false }));
  const total = planTotal(phases);
  S.buildOrders.push({ kind, b, item: item || "", idx: idx ?? -1, side, storeys,
    vol: total.vol, done: 0, phases });
  const tag = kind === "shell" ? "·新座" : kind === "floor" ? circ(idx) + "·加层" : circ(idx) + "·" + item;
  feed(`开工 ${b}${tag}——${phases.length} 道工序（预检 ${costStr(total.cost)}，逐环节扣料；总工作量 ${total.vol}）`, "good");
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
/* 筹建任务（裁决48）：在父组织面板下达——槽内在编者读条 3 时建出新组织（完成时经 createOrgAt 转任主管）
   撤走读条人＝任务作废（草台班子散伙） */
export function startOrgTask(containerId, fn, name) {
  const slot = S.orgs[containerId]?.slots[fn];
  if (!slot || slot.institution || !slot.persons.length) return;
  if (S.orgTasks.some(t => t.c === containerId && t.fn === fn)) { feed(`「${fn}」槽已有筹建任务在办`, "bad"); return; }
  const cost = LATE_COST[name] || {};
  if (cost.prereqSkill) { const why = createBlocked(name); if (why) { feed(why, "bad"); return; } }
  S.orgTasks.push({ c: containerId, fn, name, pid: slot.persons[0], prog: 0, need: 3 });
  feed(`筹建任务下达：${person(slot.persons[0])?.name} 着手筹建 ${name}（3 时成编制）`, "good");
}
function tickOrgTasks(dt) {
  for (const t of [...S.orgTasks]) {
    const slot = S.orgs[t.c]?.slots[t.fn];
    if (!slot || !slot.persons.includes(t.pid)) {   // 读条人被撤走——作废
      S.orgTasks.splice(S.orgTasks.indexOf(t), 1);
      feed(`筹建作废：${t.name}（经办人离岗）`, "warn");
      continue;
    }
    t.prog += dt;
    if (t.prog >= t.need) {
      S.orgTasks.splice(S.orgTasks.indexOf(t), 1);
      createOrgAt(t.c, t.fn, t.name);   // 完成＝即时落编（人转任主管，裁决47）
    }
  }
}
/* 点空槽自动放人（裁决48）：从待业里选最合适的——会本组织所需手艺优先、对应属性次之 */
export function putBest(orgId, fn) {
  const o = S.orgs[orgId]; const slot = o?.slots[fn];
  if (!slot || slot.institution || slot.persons.length) return false;
  const idles = idle();
  if (!idles.length) { feed("无待业者可派", "bad"); return false; }
  const orgArts = [...new Set((o.steps || []).map(st => st.art).filter(Boolean))];
  const attrKey = slot.def.terrain ? "str" : "cft";
  const best = idles.map(p => ({ p, sc: p.skills.filter(a => orgArts.includes(a)).length * 2 + (p.attr[attrKey] || 5) / 10 }))
    .sort((a, b) => b.sc - a.sc)[0].p;
  putPerson(orgId, fn, best.id);
  return true;
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
