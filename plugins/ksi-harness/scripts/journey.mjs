#!/usr/bin/env node
// journey.mjs — 여정(journey) 레인 드라이버. ui-audit §3의 '페이지 레인'과 대칭.
//
// 왜 별도인가(페르소나 감사 실측 근거): 정지 스크린샷만 받은 판독 에이전트는 프롬프트에
//   "동선을 보라"고 써도 자기가 볼 수 있는 것(타이포·터치타겟·색상)으로 퇴화한다. 실제로 어떤 감사가
//   157건을 내고도 ① 알림 패널이 뷰포트 밖(클릭해야 보임) ② 대시보드 필터 링크가 소프트 내비에서만
//   깨짐(클릭해야 보임) ③ 저장 중복 제출(느린 망 + 두 번 탭해야 보임)을 전부 놓쳤다.
//   → 여정 유닛은 '스크린샷'이 아니라 '자기 브라우저'를 받아야 한다.
//   playwright-mcp는 단일 브라우저라 fan-out 동시 사용이 불가하므로, 에이전트마다 이 러너를 각자 돌린다.
//
// 사용:
//   node ~/.claude/scripts/journey.mjs --out <dir> --paths /a,/b [--base URL]
//     [--setup ./qa-setup.mjs] [--viewport mobile-390,tablet-768,desktop-1440] [--settle 1200]
//
// 산출: <out>/<slug>.<viewport>.png + <out>/outline.json
//   outline = 페이지별 실측 — 제목/버튼(터치타겟<44px 표시)/링크/입력필드/탭/표/가로오버플로/
//             콘솔에러/실패요청/본문 프리뷰. 픽셀로는 세기 어려운 것을 숫자로 준다.
//
// 인터랙션이 더 필요하면 이 파일을 복사해 자기 스크립트를 쓴다(클릭·입력·오프라인·인쇄 등).
// playwright 해석은 cwd(프로젝트 루트) 기준 — capture.mjs와 동일 규약.

import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import process from 'node:process';

function die(code, msg) { console.error(msg); process.exit(code); }

const opt = {
  base: process.env.QA_BASE_URL ?? 'http://localhost:3000',
  out: null, paths: null, viewport: 'desktop-1440,mobile-390', settle: 1200, setup: null,
};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--base') opt.base = argv[++i];
  else if (a === '--out') opt.out = argv[++i];
  else if (a === '--paths') opt.paths = argv[++i];
  else if (a === '--viewport' || a === '--viewports') opt.viewport = argv[++i];
  else if (a === '--settle') opt.settle = Number(argv[++i]);
  else if (a === '--setup') opt.setup = argv[++i];
  else die(64, `unknown arg: ${a}`);
}
if (!opt.out || !opt.paths) die(64, 'usage: journey.mjs --out <dir> --paths /a,/b [--base URL] [--setup ./qa-setup.mjs] [--viewport ...]');

const PATHS = opt.paths.split(',').map((s) => s.trim()).filter(Boolean);
const PRESETS = {
  'mobile-390': { width: 390, height: 844 },
  'tablet-768': { width: 768, height: 1024 },
  'desktop-1440': { width: 1440, height: 900 },
};
const viewports = opt.viewport.split(',').map((v) => {
  v = v.trim();
  if (PRESETS[v]) return { key: v, ...PRESETS[v] };
  const m = v.match(/^(\d+)x(\d+)$/);
  if (m) return { key: v, width: +m[1], height: +m[2] };
  die(64, `viewport 해석 불가: ${v}`);
});

let setupFn = null;
if (opt.setup) {
  const abs = path.resolve(process.cwd(), opt.setup);
  try {
    const mod = await import(pathToFileURL(abs).href);
    setupFn = mod.default ?? mod.setup;
  } catch (e) { die(64, `--setup 로드 실패(${abs}): ${e.message}`); }
}

let chromium;
try {
  ({ chromium } = createRequire(path.join(process.cwd(), 'noop.js'))('playwright'));
} catch { die(69, 'playwright를 cwd 기준으로 찾지 못함 — 프로젝트 루트에서 실행할 것.'); }

// ⚠️ page.evaluate에 문자열을 넘기면 playwright는 그것을 **식(expression)**으로 평가한다.
//    '() => ({...})'를 그대로 넘기면 함수 객체가 만들어질 뿐 호출되지 않아 undefined가 온다.
//    아래는 즉시실행(IIFE)으로 감싸 호출한다. (이 함정으로 실측이 조용히 비는 사고가 있었다.)
const OUTLINE = `(() => {
  const vis = (el) => {
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const txt = (el) => (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 120);
  const pick = (sel) => Array.from(document.querySelectorAll(sel)).filter(vis);

  const headings = pick('h1,h2,h3').map((e) => e.tagName + ': ' + txt(e));
  const buttons = pick('button,[role=button],a[class*=btn]').map((e) => {
    const r = e.getBoundingClientRect();
    const label = txt(e) || e.getAttribute('aria-label') || '(라벨없음)';
    const small = (r.width < 44 || r.height < 44) ? \` [터치타겟 \${Math.round(r.width)}x\${Math.round(r.height)}]\` : '';
    return label + small + (e.disabled ? ' [비활성]' : '');
  });
  const links = pick('a[href]').map((e) => txt(e) + ' -> ' + e.getAttribute('href'));
  const fields = pick('input,select,textarea').map((e) => {
    const lab = e.labels && e.labels[0] ? txt(e.labels[0])
      : (e.getAttribute('aria-label') || e.getAttribute('placeholder') || '(라벨없음)');
    const rng = (e.min !== '' || e.max !== '') ? \` [범위 \${e.min || '-'}~\${e.max || '-'}]\` : '';
    return \`\${e.tagName.toLowerCase()}[\${e.type || ''}] \${lab}\${e.required ? ' *필수' : ''}\${rng}\`;
  });
  const tabs = pick('[role=tab]').map(txt).filter(Boolean);
  const tables = pick('table').map((t) => {
    const th = Array.from(t.querySelectorAll('th')).map(txt);
    const box = t.parentElement;
    const clipped = box && box.scrollWidth > box.clientWidth + 2
      ? \` [가로잘림 \${box.scrollWidth}>\${box.clientWidth}]\` : '';
    return \`열[\${th.join(' | ')}] 행수=\${t.querySelectorAll('tbody tr').length}\${clipped}\`;
  });
  const overflow = document.documentElement.scrollWidth > window.innerWidth + 2
    ? \`가로 오버플로: \${document.documentElement.scrollWidth} > \${window.innerWidth}\` : null;
  const body = (document.body.innerText || '').replace(/\\s+/g, ' ');
  const emptyHints = ['없습니다','비어','데이터가 없','조회된','결과가 없','오류','실패','로딩 중','권한이 없']
    .filter((k) => body.includes(k));

  return { headings, buttons, links, fields, tabs, tables, overflow, emptyHints,
           title: document.title, bodyLength: body.length, bodyPreview: body.slice(0, 2500) };
})()`;

mkdirSync(opt.out, { recursive: true });
const browser = await chromium.launch();
const report = { base: opt.base, setup: opt.setup, pages: [] };

for (const vp of viewports) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, locale: 'ko-KR' });
  const page = await ctx.newPage();
  const consoleErrors = [], failedReqs = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 300)); });
  page.on('requestfailed', (r) => failedReqs.push(`${r.method()} ${r.url()} :: ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400) failedReqs.push(`${r.status()} ${r.url()}`); });

  if (setupFn) {
    try { await setupFn(page, { base: opt.base, viewport: vp }); }
    catch (e) { console.error(`setup(${vp.key}) 실패: ${e.message}`); }
  }

  for (const p of PATHS) {
    const slug = p.replace(/^\//, '').replace(/[/?=&]/g, '_') || 'root';
    consoleErrors.length = 0; failedReqs.length = 0;
    let nav = 'ok';
    try {
      await page.goto(opt.base + p, { waitUntil: 'load', timeout: 30_000 });
      await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});
    } catch (e) { nav = `nav-error: ${String(e).slice(0, 120)}`; }
    await page.waitForTimeout(opt.settle);
    const file = path.join(opt.out, `${slug}.${vp.key}.png`);
    await page.screenshot({ path: file, fullPage: true }).catch(() => {});
    let outline = {};
    try { outline = (await page.evaluate(OUTLINE)) ?? { error: 'outline-empty' }; }
    catch (e) { outline = { error: String(e).slice(0, 200) }; }
    report.pages.push({
      path: p, viewport: vp.key, finalUrl: page.url(), nav, screenshot: file,
      redirected: !page.url().endsWith(p) && !page.url().includes(p),
      consoleErrors: [...new Set(consoleErrors)].slice(0, 8),
      failedRequests: [...new Set(failedReqs)].slice(0, 8),
      ...outline,
    });
    process.stderr.write(`  [${vp.key}] ${p} -> ${page.url()}\n`);
  }
  await ctx.close();
}
await browser.close();
const jsonPath = path.join(opt.out, 'outline.json');
writeFileSync(jsonPath, JSON.stringify(report, null, 2));
console.log(jsonPath);
