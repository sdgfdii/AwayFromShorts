/* ============================================================
 *  AwayFromShorts - 前端回归自检 (无需浏览器)
 *  用法: node tools/verify-frontend.js
 *  作用:
 *    1) 解析 src/web/index.html 内所有 <script> 块做语法检查 (vm.Script)
 *    2) 检查关键功能标记是否还在 (防回退)
 *    3) 检查 CSS 括号平衡 / HTML 关键标签配对
 *  退出码: 0 = 全部通过, 1 = 有失败项
 * ============================================================ */
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const file = path.join(__dirname, "..", "src", "web", "index.html");
const html = fs.readFileSync(file, "utf8");
let bad = 0;
function rep(label, ok, extra) {
  console.log((ok ? "OK  " : "FAIL") + " " + label + (extra ? " " + extra : ""));
  if (!ok) bad++;
}

/* ---------- 1. 脚本语法 ---------- */
const blocks = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (!blocks.length) rep("存在 <script> 块", false);
blocks.forEach((code, i) => {
  try { new vm.Script(code, { filename: "block" + i + ".js" }); rep("script#" + i + " 语法", true, "(" + code.length + " chars)"); }
  catch (e) { rep("script#" + i + " 语法", false, "- " + e.message); }
});

/* ---------- 2. 功能标记 ---------- */
const markers = [
  ["请求超时常量 API_TIMEOUT", /const API_TIMEOUT = 15000;/],
  ["只读请求自动重试", /_attempt < 1/],
  ["保存按钮 finally 恢复", /finally \{ btn\.disabled = false; \}/],
  ["原生控件深色 color-scheme", /color-scheme: dark;/],
  ["自动刷新周期 20s", /const AUTO_REFRESH_MS = 20000;/],
  ["自动刷新挂载", /setInterval\(autoRefresh, AUTO_REFRESH_MS\);/],
  ["后台暂停刷新", /if \(autoBusy \|\| document\.hidden\) return;/],
  ["切回前台补刷", /visibilitychange/],
  ["静默刷新 refreshStatus(silent)", /async function refreshStatus\(silent\)/],
  ["静默刷新 refreshStats(silent)", /async function refreshStats\(silent\)/],
  ["断线提示", /面板无响应/],
  ["减少动效降级", /@media \(prefers-reduced-motion: reduce\)/],
  ["侧边栏 <nav> 语义", /<nav class="sidebar" aria-label="主导航">/],
  ["role=tablist", /role="tablist" aria-orientation="vertical"/],
  ["toast aria-live", /role="status" aria-live="polite" aria-atomic="true"/],
  ["activateTab 切换函数", /function activateTab\(el\)/],
  ["方向键导航", /e\.key === "ArrowDown" \|\| e\.key === "ArrowRight"/],
  ["aria-selected 同步", /setAttribute\("aria-selected", on \? "true" : "false"\)/],
  ["可见焦点环", /:focus-visible \{ outline: 2px solid var\(--accent\)/],
  ["按钮样式复位", /width: 100%; background: transparent; font: inherit; text-align: left;/],
  ["强制模式: 星期/时段锁定", /forceLocked/],
  // 首屏健壮性 (开机后空白页回归防护)
  ["首屏分接口结算 allSettled", /Promise\.allSettled\(/],
  ["首屏退避重试 bootRetry", /function bootRetry\(/],
  ["启动即触发重试", /bootRetry\(\);/],
  ["自动刷新兜底加载", /if \(!status \|\| !cfg\) \{ await load\(\); return; \}/],
  ["状态胶囊可点击重连", /topPillEl\.addEventListener\("click"/],
  ["渲染前校验核心数据", /if \(cfg && status\) \{ renderHome\(\); renderStatus\(\); \}/],
  ["连接中提示", /正在连接面板/],
  // 视觉强化: 噪波 / 悬停高光 / 阴影 / 动效
  ["噪波: 内联 SVG 颗粒", /--noise: url\("data:image\/svg\+xml/],
  ["噪波: 全屏混合层", /mix-blend-mode: soft-light/],
  ["噪波: 第二层粗颗粒", /--noise-coarse/],
  ["悬停高光: 鼠标跟随变量", /--mx: 50%; --my: 0%;/],
  ["悬停高光: rAF 节流", /requestAnimationFrame\(\(\) =>/],
  ["悬停高光: 光斑伪元素", /radial-gradient\(240px circle at var\(--mx\) var\(--my\)/],
  ["阴影层级令牌 --sh-3", /--sh-3:/],
  ["阴影: 卡片悬停加深", /\.card:hover \{ border-color: rgba\(79,140,255,\.42\)/],
  ["动效: 切页入场 playPanelEnter", /function playPanelEnter/],
  ["动效: 入场用 backwards(不挡 hover)", /panelIn \.56s cubic-bezier\(\.22,\.9,\.3,1\) backwards/],
  ["动效: 列表插入 rowIn", /@keyframes rowIn/],
  ["动效: 柱条数值过渡", /\.bar-fill, \.vb \.bar \.col/],
  ["减少动效降级保留", /@media \(prefers-reduced-motion: reduce\)/],
  // 切页花活: 光柱 / 扫光 / 逐块飞入 / 每页色相
  ["花活: 每页色相令牌 --tab-h", /--tab-h: 218;/],
  ["花活: 滑动光柱元素", /class="nav-glow" id="navGlow"/],
  ["花活: 光柱跟随当前项", /function moveNavGlow\(el\)/],
  ["花活: 光柱弹性位移", /transform \.46s cubic-bezier\(\.3,1\.42,\.45,1\)/],
  ["花活: 全屏扫光层", /class="warp" id="warp"/],
  ["花活: 斜向扫光动画", /@keyframes warpSweep/],
  ["花活: 色相闪光", /@keyframes warpFlash/],
  ["花活: 旧页退场 panelOut", /@keyframes panelOut/],
  ["花活: 退场延时换页", /setTimeout\(swap, 170\)/],
  ["花活: 子块左右交替飞入", /@keyframes panelInAlt/],
  ["花活: 进场扫描光", /@keyframes scanDown/],
  ["花活: 导航点击冲击环", /@keyframes navBurst/],
  ["花活: 冲击环用阴影扩散(不撑滚动区)", /box-shadow: 0 0 0 11px hsl\(var\(--tab-h\)/],
  ["花活: 标题字距收拢", /@keyframes titleIn/],
  ["花活: 切页竞态防护", /if \(token !== tabSwapToken\) return;/],
];
markers.forEach(([name, re]) => rep(name, re.test(html)));

/* ---------- 2b. 后端标记 (空白页根因: /api/account 联网阻塞单线程 HTTP 服务) ---------- */
const coreFile = path.join(__dirname, "..", "src", "core.ps1");
const uiFile = path.join(__dirname, "..", "src", "webui.ps1");
try {
  const core = fs.readFileSync(coreFile, "utf8");
  const ui = fs.readFileSync(uiFile, "utf8");
  const backend = [
    ["后端: /api/account 本地缓存优先", /hasCache/, core],
    ["后端: 用户信息缓存落盘", /function Save-AfsAccountCache/, core],
    ["后端: 缓存缺失时限时补拉(6s)", /TimeoutSec 6/, core],
    ["后端: 登录成功写缓存", /Save-AfsAccountCache \$u/, ui],
  ];
  backend.forEach(([name, re, src]) => rep(name, re.test(src)));
} catch (e) { rep("读取后端脚本", false, "- " + e.message); }

/* ---------- 3. 结构平衡 ---------- */
const cnt = (re) => (html.match(re) || []).length;
const navBtn = cnt(/<button type="button" class="nav-item[^>]*>/g);
rep("侧边栏按钮数 = 7", navBtn === 7, "(实际 " + navBtn + ")");
rep("无遗留 <aside>", cnt(/<aside\b/g) === 0);
rep("<nav> 标签平衡", cnt(/<nav\b/g) === cnt(/<\/nav>/g));
const panelIds = [...html.matchAll(/id="panel-([a-z]+)"/g)].map(m => m[1]);
const tabIds = [...html.matchAll(/data-tab="([a-z]+)"/g)].map(m => m[1]);
rep("tab 与 panel 一一对应", JSON.stringify(panelIds) === JSON.stringify(tabIds), tabIds.join(","));

const css = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m => m[1]).join("\n");
const ob = (css.match(/\{/g) || []).length, cb = (css.match(/\}/g) || []).length;
rep("CSS 大括号平衡", ob === cb, ob + "/" + cb);
rep("CSS 小括号平衡", (css.match(/\(/g) || []).length === (css.match(/\)/g) || []).length,
  (css.match(/\(/g) || []).length + "/" + (css.match(/\)/g) || []).length);
rep("文档收尾完整", /<\/body>/.test(html) && /<\/html>/.test(html));

console.log(bad ? "\nRESULT: FAIL (" + bad + " 项)" : "\nRESULT: PASS");
process.exit(bad ? 1 : 0);
