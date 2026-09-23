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
  ["保存按钮 finally 恢复(含文案)", /finally \{ btn\.disabled = false; btn\.textContent = oldTxt; \}/],
  ["原生控件浅色 color-scheme", /color-scheme: light;/],
  ["浅色主题·白底", /--bg: #f4f4f0;/],
  ["浅色主题·黄主色", /--accent: #eab308;/],
  ["浅色主题·文字深黄", /--accent-text: #8f6400;/],
  ["外观切换: 暗色令牌块", /html\[data-theme="dark"\] \{/],
  ["外观切换: 预设防闪脚本", /localStorage\.getItem\("afs-theme"\)/],
  ["外观切换: 顶栏按钮", /id="themeBtn"/],
  ["外观切换: 选择持久化", /localStorage\.setItem\(THEME_KEY, t\)/],
  ["外观切换: 暗底亮黄文字", /--nav-l: 78%;/],
  ["全局滚动: 外壳不再锁死高度", /\.app \{ display: flex; min-height: 100vh; \}/],
  ["全局滚动: 侧边栏 sticky", /position: sticky; top: 0; height: 100vh/],
  ["自动刷新周期 20s", /const AUTO_REFRESH_MS = 20000;/],
  ["自动刷新挂载", /setInterval\(autoRefresh, AUTO_REFRESH_MS\);/],
  ["后台暂停刷新", /if \(autoBusy \|\| document\.hidden\) return;/],
  ["切回前台补刷", /visibilitychange/],
  ["静默刷新 refreshStatus(silent)", /async function refreshStatus\(silent\)/],
  ["静默刷新 refreshStats(silent)", /async function refreshStats\(silent, forceActivity\)/],
  // 统计页: activity(应用使用) 必须跟着刷新, 否则「每日/周/月」三个视图永远停在首屏数据
  ["统计: 刷新同时拉 activity", /async function refreshActivity\(silent\)/],
  ["统计: 刷新统计并发拉两条数据源", /Promise\.allSettled\(needAct \? \[api\("\/api\/stats"\), api\("\/api\/activity"\)\]/],
  ["统计: 渲染与请求失败分离", /function safeRenderStats\(\)/],
  ["统计: 界面显示刷新时间", /已更新 " \+ statsStamp\(\)/],
  ["统计: 连接类失败静默退避重试", /function statsScheduleRetry\(\)/],
  ["统计: 刷新状态行存在", /id="statsUpdated"/],
  ["统计: 视图切换补拉 activity", /if \(statsNeedsActivity\(\) && Date\.now\(\) - actLast > 20000\)/],
  ["统计: 首屏先落 activity 再渲染", /activity = act\.value\.activity; actLast = Date\.now\(\);\s*\}\s*if \(st\.status === "fulfilled" && st\.value\) stats = st\.value\.stats;/],
  ["断线提示", /面板无响应/],
  // v1.4.0 优化: 稳定性/性能守卫
  ["倒计时后台暂停", /if \(!homeCountdown \|\| document\.hidden\) return;/],
  ["状态操作防连点 actBusy", /let actBusy = false;/],
  ["状态操作不强制拉 activity", /Promise\.all\(\[refreshStatus\(\), refreshStats\(true\)\]\)/],
  ["队列落地不覆盖未保存编辑", /if \(dirty\) \{\s*\/\/ 表单里有未保存的编辑/],
  ["统计重试后台/离页即停", /if \(document\.hidden \|\| !panelActive\) \{ statsAttempt = 0; return; \}/],
  ["手动重连取消排队重试", /clearTimeout\(bootTimer\); bootTimer = null; bootAttempt = 0;/],
  ["ensureBrowser 兜底函数", /function ensureBrowser\(\)/],
  ["空时段诚实空状态(不伪造 19:00)", /id="windowEmpty"/],
  ["空时段走三元分支而非回写配置", /\$\("#windowRows"\)\.innerHTML = ws\.length \? ws\.map/],
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
  // 强制模式开启期间: 「屏蔽网页 / 屏蔽进程 / 白名单」改为排队(非屏蔽时段自动生效);
  // 「屏蔽星期 / 屏蔽时段」与「从云端拉取配置」仍是硬锁。
  ["排队: 补丁深合并(不丢嵌套键)", /function deepMergePatch\(target, patch\)/],
  ["排队: 叠加到展示态", /function applyPendingToView\(p\)/],
  ["排队: 状态变量 pendingInfo", /let pendingInfo = null;/],
  ["排队: 顶栏待生效胶囊", /id="pendingPill"/],
  ["排队: 黄色提示条样式", /\.queue-note \{/],
  ["排队: 按类目取排队条目", /function pendingItemsFor\(sel\)/],
  ["排队: 撤销排队按钮", /class="btn small pending-clear"/],
  ["排队: 撤销走 /api/pending/clear", /"\/api\/pending\/clear", "POST", \{\}/],
  ["排队: 保存后按 queued 区分提示", /if \(r\.queued\) toast\("⏳ 已排队/],
  ["排队: 队列变化后重新拉配置", /if \(qBefore !== qAfter\)/],
  ["强制模式: 锁定提示 helper", /function applyLockNote\(/],
  ["强制模式: 禁用+整行变灰 helper", /function setLocked\(/],
  ["强制模式: 硬锁行整行变灰", /row\.classList\.toggle\("locked", !!locked\)/],
  ["强制模式: 屏蔽网页提示位", /id="sitesLockNote"/],
  ["强制模式: 屏蔽进程提示位", /id="procLockNote"/],
  ["强制模式: 白名单提示位", /id="wlLockNote"/],
  ["强制模式: 同步拉取硬锁提示位", /id="syncLockNote"/],
  ["强制模式: 渲染时调用提示", /applyLockNote\("#sitesLockNote", locked,/],
  ["强制模式: 云端拉取硬锁 toast", /「从云端拉取配置」不可用/],
  // 生效时段内「只能增不能删」: 收紧方向可排队, 放宽方向直接拒绝
  ["收紧: tightenOnly 开关", /const tightenOnly = \(\) => forceLocked\(\) && forceActiveNow;/],
  ["收紧: 放宽提示 helper", /function tightenToast\(what, why\)/],
  ["收紧: 屏蔽名单种类表", /const SHIELD_KIND = \{ site:/],
  ["收紧: 删除按钮按 tightenOnly 禁用", /renderList\("#siteList", cfg\.blockedSites, "site", ro, "强制模式生效中: 只能新增域名, 不能删除"\)/],
  ["收紧: 工作区删除按钮禁用", /renderList\("#browserWinList", cfg\.browser\.windows, "bwin", ro,/],
  ["收紧: 进程删除按钮禁用", /renderList\("#procList", cfg\.blockedProcesses, "proc", ro,/],
  ["收紧: 删除事件二次守卫", /if \(SHIELD_KIND\[kind\] && tightenOnly\(\)\)/],
  ["收紧: 网站预设取消勾选拦截", /tightenToast\("「屏蔽网页」域名", "取消勾选等于删掉这些域名"\)/],
  ["收紧: 进程预设取消勾选拦截", /tightenToast\("「屏蔽进程」", "取消勾选等于删掉这些进程"\)/],
  ["收紧: 白名单新增拦截", /tightenToast\(kind === "wlsite" \? "「白名单域名」" : "「白名单进程」", "加入白名单等于变相放行"\)/],
  ["收紧: 白名单输入框禁用", /setLocked\("#addWlSiteBtn", ro\)/],
  ["收紧: 总开关开关不能关", /if \(tightenOnly\(\) && !e\.target\.checked\)/],
  ["收紧: 工作区/网址拦截开关不能关", /tightenToast\("「网址拦截」开关"/],
  ["收紧: 卡片琥珀色受限边框", /\.preset\.tighten \{ border-color: rgba\(255,176,32,\.3\); \}/],
  ["收紧: 提示条按方向措辞", /const rule = shrink \? "只能减少, 不能新增" : "只能新增, 不能删减";/],
  ["收紧: 强制卡片同步说明", /只能收紧不能放宽/],
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
  ["阴影: 卡片悬停加深", /\.card:hover \{ border-color: rgba\(234,179,8,\.42\)/],
  ["动效: 切页入场 playPanelEnter", /function playPanelEnter/],
  ["动效: 入场用 backwards(不挡 hover)", /panelIn \.56s cubic-bezier\(\.22,\.9,\.3,1\) backwards/],
  ["动效: 列表插入 rowIn", /@keyframes rowIn/],
  ["动效: 柱条数值过渡", /\.bar-fill, \.vb \.bar \.col/],
  ["减少动效降级保留", /@media \(prefers-reduced-motion: reduce\)/],
  // 切页花活: 光柱 / 扫光 / 逐块飞入 / 每页色相
  ["花活: 每页色相令牌 --tab-h", /--tab-h: 45;/],
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
const engineFile = path.join(__dirname, "..", "src", "awayfromshorts.ps1");
try {
  const core = fs.readFileSync(coreFile, "utf8");
  const ui = fs.readFileSync(uiFile, "utf8");
  const engine = fs.readFileSync(engineFile, "utf8");
  const backend = [
    ["后端: /api/account 本地缓存优先", /hasCache/, core],
    ["后端: 用户信息缓存落盘", /function Save-AfsAccountCache/, core],
    ["后端: 缓存缺失时限时补拉(6s)", /TimeoutSec 6/, core],
    ["后端: 登录成功写缓存", /Save-AfsAccountCache \$u/, ui],
    // 运行时文件(stats/activity)由主引擎高频写入, 非原子写会让面板读到半截 JSON
    ["后端: 运行时文件原子写", /function Write-AfsTextAtomic/, core],
    ["后端: 读文件短重试", /function Read-AfsTextRetry/, core],
    ["后端: stats 读取走重试+进程内缓存", /Read-AfsTextRetry -Path \$p[\s\S]{0,200}afsStatsCache/, core],
    ["后端: activity 读取走重试+进程内缓存", /Read-AfsTextRetry -Path \$p[\s\S]{0,200}afsActivityCache/, core],
    ["后端: stats 落盘用原子写", /Write-AfsTextAtomic -Path \(Get-AfsStatsPath\)/, core],
    ["后端: activity 落盘用原子写", /Write-AfsTextAtomic -Path \(Get-AfsActivityPath\)/, core],
    // 强制模式开启期间的改动处理 (防破戒):
    //   硬拒 = 屏蔽星期 / 屏蔽时段 (它们定义了"何时算非屏蔽时段")
    //   可排队 = 屏蔽网页 / 屏蔽进程 / 白名单 (生效时段内先入队, 非屏蔽时段由引擎自动落地)
    // 判据集中在 core.ps1 的 Get-AfsConfigLockDiff, 离线回归见 tools/verify-lock.ps1
    ["后端: 名单签名归一化函数", /function Get-AfsListSignature/, core],
    ["后端: 名单差异摘要", /function Get-AfsListDelta/, core],
    ["后端: 名单新增项判定", /function Get-AfsListAdded/, core],
    ["后端: 名单删除项判定", /function Get-AfsListRemoved/, core],
    ["后端: 锁定分类(硬拒/放宽/收紧)", /function Get-AfsConfigLockDiff/, core],
    ["后端: 兼容入口 Test-AfsConfigLockViolation", /function Test-AfsConfigLockViolation/, core],
    ["后端: 兼容入口支持 -ForceActive", /\[switch\]\$ForceActive/, core],
    ["后端: 屏蔽星期=硬拒", /Get-AfsListSignature \$Current\.schedule\.days/, core],
    ["后端: 屏蔽时段=硬拒", /Get-AfsListSignature \$curWin\) -ne \(Get-AfsListSignature \$newWin/, core],
    ["后端: 删屏蔽域名=放宽", /Get-AfsListRemoved -Old \$Current\.blockedSites -New \$Incoming\.blockedSites/, core],
    ["后端: 加屏蔽域名=收紧(排队)", /Get-AfsListAdded   -Old \$Current\.blockedSites -New \$Incoming\.blockedSites/, core],
    ["后端: 删屏蔽进程=放宽", /Get-AfsListRemoved -Old \$Current\.blockedProcesses -New \$Incoming\.blockedProcesses/, core],
    ["后端: 删 Edge 工作区=放宽", /Get-AfsListRemoved -Old \(\$Current\.browser\)\.windows/, core],
    ["后端: 关屏蔽开关=放宽", /\$curWeb\) \{/, core],
    ["后端: 加白名单=放宽", /Get-AfsListAdded   -Old \(\$Current\.whitelist\)\.sites/, core],
    ["后端: 收窄提示 widenMsg", /\$widenMsg = '强制模式生效中, 屏蔽网页名单/, core],
    ["后端: 排队补丁生成", /function New-AfsPendingPatch/, core],
    ["后端: 补丁只收新增项", /\$grouped\.sites = \[string\[\]\]@\(\$adSites \| ForEach-Object \{ "\+ \$_" \}\)/, core],
    ["后端: 队列落盘 pending-config.json", /function Save-AfsPendingQueue/, core],
    ["后端: 队列读取", /function Read-AfsPendingQueue/, core],
    ["后端: 队列清除", /function Remove-AfsPendingQueue/, core],
    ["后端: 队列落地入口", /function Invoke-AfsPendingApply/, core],
    ["后端: 落地做只收紧合并", /function Merge-AfsPendingTighten/, core],
    ["后端: 合并=屏蔽名单取并集", /\$out\.blockedSites = @\(Normalize-AfsList \(@\(\$Base\.blockedSites\) \+ \$pSites\)/, core],
    ["后端: 合并=白名单取交集", /if \(\$null -eq \$keepS\) \{ @\(\(\$Base\.whitelist\)\.sites\) \}/, core],
    ["后端: 合并=开关取或", /\$out\.blockWebsites = \[bool\]\(\[bool\]\$Base\.blockWebsites -or \[bool\]\$Patch\.blockWebsites\)/, core],
    ["后端: 合并只认名单字段", /# 只认这几个字段, 补丁里夹带的其他键\(如 schedule\)一律不生效/, core],
    ["后端: 生效时段内不落地", /reason = 'force-active'/, core],
    ["后端: 面板调用分类判据", /Get-AfsConfigLockDiff -Current \$curCfg -Incoming \$inCfg/, ui],
    ["后端: 生效时段内拒绝放宽", /if \(\$forceNow\.active -and \$diff\.widenMsg\) \{ throw \$diff\.widenMsg \}/, ui],
    ["后端: 生效时段内改为排队", /Save-AfsPendingQueue -Current \$curCfg -Incoming \$inCfg/, ui],
    ["后端: 保存响应带 queued", /queued\s+= \$true/, ui],
    ["后端: 排队清除接口", /'\/api\/pending\/clear'/, ui],
    ["后端: config 接口带 pending", /pending\s+= \(Read-AfsPendingQueue\)/, ui],
    ["后端: status 接口带 pending", /pending\s+= \(Read-AfsPendingQueue\)/, ui],
    ["后端: 主引擎落地排队", /Invoke-AfsPendingApply -Config \$cfg/, engine],
    ["后端: 强制中禁止云端拉取覆盖", /强制模式开启中, 无法从云端拉取配置/, core],
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
