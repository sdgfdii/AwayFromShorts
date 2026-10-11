// 风格 DNA 校验 v2 —— 避开 jsdom 的两处已知局限:
//   1) jsdom 不解析 shorthand 里的 var() (background/border-radius 会留原文)
//   2) jsdom 不解析 transition 简写里的 var() 时长
// 改为: 用 css-tree 解析真实 <style>, 把 token 表解析出来后, 对声明做变量代换再断言。
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

// 把 :root 里的自定义属性抽出来
function collectTokens(ast) {
  const toks = {};
  csstree.walk(ast, {
    visit: "Rule",
    enter(node) {
      const sel = csstree.generate(node.prelude);
      if (sel !== ":root") return;
      if (!node.block) return;
      node.block.children.forEach(decl => {
        if (decl.type !== "Declaration") return;
        if (!decl.property.startsWith("--")) return;
        toks[decl.property] = csstree.generate(decl.value).trim();
      });
    }
  });
  return toks;
}

// 找到某个选择器下某属性的值(最后一条生效的)
function propOf(ast, selector, prop) {
  let val = null;
  csstree.walk(ast, {
    visit: "Rule",
    enter(node) {
      const sel = csstree.generate(node.prelude);
      if (sel !== selector) return;
      if (!node.block) return;
      node.block.children.forEach(decl => {
        if (decl.type === "Declaration" && decl.property === prop) {
          val = csstree.generate(decl.value).trim();
        }
      });
    }
  });
  return val;
}

// 变量代换: 反复替换 var(--x) / var(--x, fallback)
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

  const toks = collectTokens(ast);
  console.log("== tokens ==");
  ["--bg","--surface","--text-primary","--text-secondary","--brand","--border","--radius","--radius-pill"].forEach(k => {
    console.log("  " + k + " = " + toks[k]);
  });

  // 1. body 背景 = #08090a
  const bodyBg = resolve(propOf(ast, "body", "background"), toks) || resolve(propOf(ast, "body", "background-color"), toks);
  chk("1. body 背景 = #08090a", /#08090a/i.test(String(bodyBg)), String(bodyBg));

  // 2. H1 负字距(非 normal)
  const h1Ls = propOf(ast, ".topbar h1", "letter-spacing");
  chk("2. H1 letter-spacing 非 normal", h1Ls != null && !/normal/i.test(h1Ls), String(h1Ls));

  // 3. 主按钮圆角 = 胶囊
  const btnR = resolve(propOf(ast, ".btn", "border-radius"), toks);
  chk("3. 按钮圆角 = 胶囊(9999px)", /9999px/.test(String(btnR)), String(btnR));

  // 4. 卡片/容器圆角 = 6px 档
  const cardR = resolve(propOf(ast, ".card", "border-radius"), toks);
  chk("4. 卡片圆角 = 6px", /6px/.test(String(cardR)), String(cardR));

  // 5. 过渡时长 = .18s
  const btnT = resolve(propOf(ast, ".btn", "transition"), toks);
  chk("5. 按钮过渡含 .18s", /\.18s|0\.18s/.test(String(btnT)), String(btnT));

  // 6. 禁用属性不存在
  const banned = {
    "linear-gradient": /linear-gradient/,
    "radial-gradient": /radial-gradient/,
    "backdrop-filter": /backdrop-filter/,
  };
  Object.keys(banned).forEach(k => chk("6. 无 " + k, !banned[k].test(css), "found"));

  // 7. 静态容器零投影
  const noShadowSelectors = [".card", ".home-kpi", ".preset", ".status-cell", ".pill"];
  let shadowOffenders = [];
  noShadowSelectors.forEach(sel => {
    const sv = resolve(propOf(ast, sel, "box-shadow"), toks);
    // 允许 none; 有非 none 值记为违规
    if (sv != null && !/^none$/i.test(sv)) shadowOffenders.push(sel + "=" + sv);
  });
  chk("7. 静态容器零投影", shadowOffenders.length === 0, shadowOffenders.join(", "));

  // 8. 品牌色 = #5e6ad2
  chk("8. 品牌色 = #5e6ad2", /#5e6ad2/i.test(String(toks["--brand"])), String(toks["--brand"]));

  // 9. 边框 = 8% 白
  chk("9. 边框 = #ffffff14", /#ffffff14/i.test(String(toks["--border"])), String(toks["--border"]));

  // 10. 阴影令牌全为 none(除 var(--shadow) 用于 toast/modal)
  chk("10. --sh-1/2/3 = none", /none/i.test(String(toks["--sh-1"])) && /none/i.test(String(toks["--sh-2"])) && /none/i.test(String(toks["--sh-3"])), toks["--sh-1"] + "/" + toks["--sh-2"] + "/" + toks["--sh-3"]);

  // 11. 无黄色残留
  chk("11. 无旧黄色令牌残留", !/#eab308|#facc15|#f59e0b/i.test(css), "found yellow");

  // 12. body 文字色
  const bodyC = resolve(propOf(ast, "body", "color"), toks);
  chk("12. body 文字 = #f7f8f8", /#f7f8f8/i.test(String(bodyC)), String(bodyC));

  // 13. 无 translateY(-Npx) scale 悬浮
  chk("13. 无悬浮位移+缩放", !/translateY\(-\d+px\)\s*scale/.test(css), "found");

  // 14. 无按钮发光
  chk("14. 无 box-shadow 发光", !/box-shadow:\s*0 0 \d+px\s+(?!inset)/.test(css), "found");

  // 15. 圆角令牌齐备
  chk("15. 圆角令牌齐备", /6px/.test(toks["--radius"] || "") && /9999px/.test(toks["--radius-pill"] || ""), (toks["--radius"]||"") + "/" + (toks["--radius-pill"]||""));

  // 16. color-scheme dark
  chk("16. color-scheme: dark", /color-scheme:\s*dark/i.test(css), "no");

  // 17. 大标题字重收紧(Linear 用 590)
  const h1W = propOf(ast, ".topbar h1", "font-weight");
  chk("17. H1 字重 = 590", /590/.test(String(h1W)), String(h1W));

  console.log("");
  console.log("== " + pass + " PASS / " + fail + " FAIL ==");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("FATAL", e.message); process.exit(1); });
