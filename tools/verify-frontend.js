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
];
markers.forEach(([name, re]) => rep(name, re.test(html)));

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
