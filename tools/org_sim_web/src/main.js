import { createApp } from "vue";
import App from "./App.vue";
import "./style.css";
import { S, advance, reset, createOrgAt, putPerson, queueBuild, setProduct, delOrg } from "./sim.js";

// dev 调试钩子：浏览器自动化与控制台可直接驱动模拟（生产构建不含）
if (import.meta.env.DEV)
  window.__sim = { S, advance, reset, ops: { createOrgAt, putPerson, queueBuild, setProduct, delOrg } };

createApp(App).mount("#app");
