import { createApp } from "vue";
import App from "./App.vue";
import "./style.css";
import { S, advance, reset, createOrgAt, putPerson, queueBuild, delOrg, loadDemo, housingCap, cityCells, capTotal, resTotal, pullPersons } from "./sim.js";

// dev 调试钩子：浏览器自动化与控制台可直接驱动模拟（生产构建不含）
if (import.meta.env.DEV)
  window.__sim = { S, advance, reset, loadDemo, housingCap, cityCells, capTotal, resTotal,
                  ops: { createOrgAt, putPerson, pullPersons, queueBuild, delOrg } };

createApp(App).mount("#app");
