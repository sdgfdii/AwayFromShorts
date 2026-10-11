// 风格 DNA 校验 —— 当前皮肤: bilibili 中文门户 (对照 design-spec-bilibili.md)
// 用 css-tree 解析真实 <style>, 抽 :root 令牌表 + 递归代换 var() 后断言。
// (不用 jsdom: 它不代换「简写属性」里的 var(), 会误报 —— 见 2026-10-11 记忆)
const http = require("http");
const csstree = require("css-tree");

function get(url) {
  return new Promise((res, rej) => {
    http.get(url, r => { let b = ""; r.on("data", d => b += d); r.on("end", () => res(b)); }).on("error", rej);
  });
}

let pass = 0, fail = 0;
function chk(name, cond, detail) {
  if (cond) { pass++; console.log("PASS  " + name); }
  else { fail++; console.log("FAIL  " + name + "   -> " + detail); }
}

function collectTokens(ast, selector) {
  const toks = {};
  csstree.walk(ast, { visit: "Rule", enter(node) {
    if (csstree.generate(node.prelude) !== selector) return;
    if (!node.block) return;
    node.block.children.forEach(d => {
      if (d.type !== "Declaration" || !d.property.startsWith("--")) return;
      toks[d.property] = csstree.generate(d.value).trim();
    });
  }});
  return toks;
}

// 浅色 :root + 暗色 html[data-theme="dark"] 合并(后者覆盖前者)
function collectAllTokens(ast) {
  return Object.assign(collectTokens(ast, ":root"), collectTokens(ast, 'html[data-theme="dark"]'));
}

function propOf(ast, selector, prop) {
  let val = null;
  csstree.walk(ast, { visit: "Rule", enter(node) {
    if (csstree.generate(node.prelude) !== selector) return;
    if (!node.block) return;
    node.block.children.forEach(d => {
      if (d.type === "Declaration" && d.property === prop) val = csstree.generate(d.value).trim();
    });
  }});
  return val;
}

function resolve(val, toks, depth = 0) {
  if (val == null || depth > 10) return val;
  const before = val;
  val = val.replace(/var\(\s*(--[a-z0-9-]+)\s*(?:,\s*([^)]*))?\)/gi, (m, name, fb) => {
    if (toks[name] != null) return toks[name];
    return fb != null ? fb.trim() : m;
  });
  return val === before ? val : resolve(val, toks, depth + 1);
}

(async () => {
  const html = await get("http://127.0.0.1:8737/");
  const m = html.match(/<style[^>]*>([\s\S]*?)<\/style>/i);
  if (!m) { console.log("FATAL no style"); process.exit(1); }
  const css = m[1];
  const ast = csstree.parse(css, { positions: true });
  // 浅色只看 :root; 暗色看 :root + dark 覆盖。两者分开, 免得互相污染。
  const toks = collectTokens(ast, ":root");
  const darkToks = Object.assign({}, toks, collectTokens(ast, 'html[data-theme="dark"]'));

  console.log("== tokens ==");
  ["--bg","--surface","--panel2","--text-primary","--text-secondary","--text-tertiary",
   "--brand","--brand-pink","--border","--border2","--border-hover","--radius","--radius-lg","--nav-l"]
    .forEach(k => console.log("  " + k + " = " + toks[k]));

  chk("1. 页面底 = #f1f2f3 (Ga1/bg3)", /#f1f2f3/i.test(String(toks["--bg"])), String(toks["--bg"]));
  chk("2. 卡片面 = #ffffff (bg1)", /#ffffff/i.test(String(toks["--surface"])), String(toks["--surface"]));
  chk("3. 主文字 = #18191c (Ga10/text1)", /#18191c/i.test(String(toks["--text-primary"])), String(toks["--text-primary"]));
  chk("4. 次文字 = #61666d (Ga7/text2)", /#61666d/i.test(String(toks["--text-secondary"])), String(toks["--text-secondary"]));
  chk("5. 三级文字 = #9499a0 (Ga5/text3)", /#9499a0/i.test(String(toks["--text-tertiary"])), String(toks["--text-tertiary"]));
  chk("6. 品牌蓝 = #00aeec (brand_blue)", /#00aeec/i.test(String(toks["--brand"])), String(toks["--brand"]));
  chk("7. 品牌粉 = #ff6699 (brand_pink)", /#ff6699/i.test(String(toks["--brand-pink"])), String(toks["--brand-pink"]));
  chk("8a. border = #e3e5e7 (line_regular)", /#e3e5e7/i.test(String(toks["--border"])), String(toks["--border"]));
  chk("8b. border2 = #f1f2f3 (line_light)", /#f1f2f3/i.test(String(toks["--border2"])), String(toks["--border2"]));
  chk("8c. border-hover = #c9ccd0 (line_bold)", /#c9ccd0/i.test(String(toks["--border-hover"])), String(toks["--border-hover"]));
  chk("9. 圆角基准 = 6px", /^6px$/i.test(String(toks["--radius"])), String(toks["--radius"]));

  const bigR = [];
  csstree.walk(ast, { visit: "Declaration", enter(d) {
    if (d.property !== "border-radius") return;
    const v = csstree.generate(d.value);
    (v.match(/(\d+(?:\.\d+)?)px/g) || []).map(x => parseFloat(x)).forEach(n => { if (n > 12) bigR.push(v); });
  }});
  chk("10. 禁止 >12px 圆角 (spec §8-3)", bigR.length === 0, bigR.join(", "));
  chk("11. 无胶囊圆角 (9999px)", !/9999px/.test(css), "found 9999px");

  chk("12a. green = #2ac864 (success)", /#2ac864/i.test(String(toks["--green"])), String(toks["--green"]));
  chk("12b. red = #f85a54 (stress)", /#f85a54/i.test(String(toks["--red"])), String(toks["--red"]));
  chk("12c. orange = #ff7f24 (operate)", /#ff7f24/i.test(String(toks["--orange"])), String(toks["--orange"]));
  chk("12d. yellow = #ffb027 (pay)", /#ffb027/i.test(String(toks["--yellow"])), String(toks["--yellow"]));

  const off = [];
  [".card",".home-kpi",".preset",".status-cell",".pill",".chip",".btn",".vcard",".hero-metric",".list-item"].forEach(sel => {
    const v = resolve(propOf(ast, sel, "box-shadow"), toks);
    if (v != null && !/^none$/i.test(v)) off.push(sel + "=" + v);
  });
  chk("13. 静态容器零投影 (spec §8-5)", off.length === 0, off.join(", "));
  chk("14. --sh-1/2/3 = none", /none/i.test(String(toks["--sh-1"])) && /none/i.test(String(toks["--sh-2"])) && /none/i.test(String(toks["--sh-3"])), "-");
  chk("15a. 无 linear-gradient", !/linear-gradient/.test(css), "found");
  chk("15b. 无 radial-gradient", !/radial-gradient/.test(css), "found");
  chk("15c. 无 backdrop-filter", !/backdrop-filter/.test(css), "found");

  const h1ls = propOf(ast, ".topbar h1", "letter-spacing");
  chk("16. H1 字距 = normal (spec §4.2)", /normal/i.test(String(h1ls)), String(h1ls));
  chk("17a. H1 字号 = 24px", /24px/.test(String(propOf(ast, ".topbar h1", "font-size"))), String(propOf(ast, ".topbar h1", "font-size")));
  chk("17b. H1 字重 = 500", /500/.test(String(propOf(ast, ".topbar h1", "font-weight"))), String(propOf(ast, ".topbar h1", "font-weight")));

  const btnT = resolve(propOf(ast, ".btn", "transition"), toks);
  chk("18. 按钮过渡含 .15s (spec §7)", /\.15s|0\.15s/.test(String(btnT)), String(btnT));
  chk("19. 无弹跳曲线 cubic-bezier(.34,1.56)", !/\.34,\s*1\.56/.test(css), "found");
  chk("20. 字体含 PingFang SC / HarmonyOS", /PingFang SC/.test(css) && /HarmonyOS/.test(css), "missing");
  chk("21. color-scheme: light", /color-scheme:\s*light/i.test(css), "no");
  chk("22. 无 Linear 色残留", !/#5e6ad2|#08090a|#8a8f98|#0f1011/i.test(css), "found");
  chk("23. 无旧亮黄 #eab308/#facc15", !/#eab308|#facc15/i.test(css), "found");
  chk("24. 无光柱/扫光/噪波残留", !/navGlow|TAB_HUE|warp|--noise/i.test(css), "found");
  chk("25. 品牌粉有 _thin 浅底 #ffecf1", /#ffecf1/i.test(css), "missing");

  // ---- b 站深夜模式 (html[data-theme="dark"]) ----
  const bare = collectTokens(ast, 'html[data-theme="dark"]');   // 只取 dark 块里显式声明的
  chk("26. 暗色块存在且换底", !!bare["--bg"] && bare["--bg"] !== toks["--bg"], String(bare["--bg"]));
  chk("27. 暗色底 = #17181a", /#17181a/i.test(String(bare["--bg"])), String(bare["--bg"]));
  chk("28. 暗色卡片面 ≠ 底(有层级)", !!darkToks["--surface"] && darkToks["--surface"] !== darkToks["--bg"], String(darkToks["--surface"]));
  chk("29. 暗色主文字为亮档", /#e3e5e7|#f/i.test(String(bare["--text-primary"])), String(bare["--text-primary"]));
  chk("30. 暗色边框与底可区分", !!bare["--border"] && bare["--border"] !== toks["--border"], String(bare["--border"]));
  chk("31. 暗色 color-scheme: dark", /color-scheme:\s*dark/i.test(css), "no");
  chk("32. 暗色阴影加深", /rgba\(0,0,0,\.4\)/.test(String(darkToks["--shadow"])), String(darkToks["--shadow"]));
  chk("33. 暗色 nav-l 取亮档", /6[0-9]%|7[0-9]%/.test(String(darkToks["--nav-l"])), String(darkToks["--nav-l"]));

  console.log("");
  console.log("== " + pass + " PASS / " + fail + " FAIL ==");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FATAL", e.message); process.exit(1); });
