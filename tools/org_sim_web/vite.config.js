import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import { viteSingleFile } from "vite-plugin-singlefile";

// dev: npm run dev（HMR 快速迭代）；build: 产出单文件 dist/index.html（双击即开）
export default defineConfig({
  plugins: [vue(), viteSingleFile()],
  base: "./",
});
