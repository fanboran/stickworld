import { ref } from "vue";

/* VSCode 式侧栏拖拽（修改必读 #12：侧栏可拖拽调尺寸、宽度记忆）：
   拖手柄调尺寸、双击回默认、localStorage 记忆。
   axis="x"＝右置侧栏的竖直手柄（向左拖=变宽）；axis="y"＝底置面板的水平手柄（向下拖=变高） */
export function usePanelSize(key, axis, def, min, max) {
  const clamp = v => Math.min(max, Math.max(min, v));
  const size = ref(clamp(Number(localStorage.getItem("pz." + key)) || def));
  function onDown(e) {
    e.preventDefault();
    const startPt = axis === "x" ? e.clientX : e.clientY;
    const startSize = size.value;
    const move = ev => {
      const cur = axis === "x" ? ev.clientX : ev.clientY;
      size.value = clamp(startSize + (axis === "x" ? startPt - cur : cur - startPt));
    };
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      document.body.classList.remove("dragging-panel-" + axis);
      localStorage.setItem("pz." + key, String(Math.round(size.value)));
    };
    document.body.classList.add("dragging-panel-" + axis);   // 拖拽期间全局锁定光标与选区
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  }
  const onDbl = () => { size.value = def; localStorage.setItem("pz." + key, String(def)); };
  return { size, onDown, onDbl };
}
