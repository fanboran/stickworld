import { createApp } from "vue";
import App from "./App.vue";
import "./style.css";
import { S, advance, reset, createOrgAt, putPerson, queueBuild, delOrg, loadDemo, housingCap, cityCells,
         capTotal, resTotal, pullPersons, mineBufCap, satWarehouses, cancelBuild, dismantle,
         buildBlocked, cityLayout, stallInfo, saveState, hasSave, loadState, clearSave,
         planOf, planTotal, tabUnlocked, hasDesigner, startOrgTask, putBest, crewCounts } from "./sim.js";

// 存档恢复先于挂载：刷新/重开浏览器不丢城（重开按钮才清档）
if (hasSave()) loadState();

// dev 调试钩子：浏览器自动化与控制台可直接驱动模拟（生产构建不含）
if (import.meta.env.DEV)
  window.__sim = { S, advance, reset, loadDemo, housingCap, cityCells, capTotal, resTotal,
                  mineBufCap, satWarehouses, createOrgAt, putPerson, pullPersons, queueBuild, delOrg,
                  cancelBuild, dismantle, buildBlocked, cityLayout, stallInfo, saveState, loadState, clearSave,
                  planOf, planTotal, tabUnlocked, hasDesigner, startOrgTask, putBest, crewCounts };

createApp(App).mount("#app");
