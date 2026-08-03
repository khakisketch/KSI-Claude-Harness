#!/usr/bin/env node
// capture.mjs — 시각-QA 캡처 러너 (ui-audit §2 local/CI 공용 — 게이트가 아니라 캡처 자체를 싸게).
//
// 픽셀 불변 원칙: 시각 감사의 입력을 바꾸는 최적화(폰트/이미지 차단, scale 축소)는 하지 않는다.
//   싸게 만드는 레버는 픽셀-중립만: 애니메이션 고정(reduced-motion+CSS) · 트래커 차단 · self-nice · 부하 적응 동시성.
//
// 조용한 실패 금지(실측 근거): 인증 앱을 --setup 없이 캡처하면 전 페이지가 로그인 화면
//   사본이 되는데, 과거 버전은 "4/4 shots" + exit 0으로 완전 성공을 보고했다. 이제 캡처 후
//   ① 동일 해시 감지 ② 리다이렉트 기록 ③ 로그인 화면 고착 감지로 DEGRADED(exit 3)를 강제한다.
//   (같은 증상을 내는 CORS 미설정 사고도 이 감지에 걸린다.)
//
// 사용:
//   node ~/.claude/scripts/capture.mjs --pages <pages.json 경로 | '[{"key":"dash","path":"/"}]'>
//     [--base http://localhost:3000] [--out shots] [--viewports mobile-390,tablet-768,desktop-1440|800x600]
//     [--setup ./qa-setup.mjs] [--no-fullpage] [--settle 300] [--concurrency N] [--allow-identical]
//
// pages 항목: { key, path, do?, settle? }
//   do = 캡처 직전 실행할 인터랙션 스텝 배열 — 정지 스크린샷이 못 잡는 '열린 상태'를 캡처 대상으로 만든다.
//        {click:sel} {fill:sel,value:v} {select:sel,value:v} {press:key} {hover:sel}
//        {scroll:'bottom'|'top'|숫자} {wait:ms} {waitFor:sel} {offline:true|false} {emulate:'print'|'screen'}
//        예) 알림 패널이 뷰포트 밖으로 열리는 결함:
//            {"key":"bell-open","path":"/dashboard","do":[{"click":"[aria-label*='알림']"}]}
//
// --setup: 컨텍스트마다 1회 실행되는 로그인/시드 훅.
//   `export default async function setup(page, { base, viewport }) { ... }` 를 default export 한다.
//   (인증 뒤에 있는 앱은 이게 없으면 로그인 화면만 찍힌다 — 아래 감지가 잡아 DEGRADED로 세운다.)
//
// 산출: <out>/<key>--<viewport>.png + <out>/manifest.json
//   manifest = 샷별 {key, viewport, path, finalUrl, redirected, bytes, sha1, consoleErrors, failedRequests}
//   → 리다이렉트되는 죽은 메뉴·CSP 차단·API 실패가 픽셀을 보기 전에 드러난다.
//
// CI: 이 파일을 repo scripts/visual-qa-capture.mjs로 복사해 쓴다(외부 의존 0 — templates/visual-qa.yml 참조).
// playwright 해석: 실행 cwd(프로젝트 루트) 기준 — 프로젝트에 설치된 버전을 쓴다.
// exit: 0=전체 성공, 3=부분 실패 또는 DEGRADED(동일 해시/인증 의심), 64=usage, 69=playwright 미설치.

import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import process from 'node:process';

function die(code, msg) { console.error(msg); process.exit(code); }

// --- args ---
const opt = {
  base: process.env.QA_BASE_URL ?? 'http://localhost:3000',
  out: 'shots', viewports: 'mobile-390,tablet-768,desktop-1440',
  fullpage: true, settle: 300, concurrency: 0, pages: null,
  setup: null, allowIdentical: false,
};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--base') opt.base = argv[++i];
  else if (a === '--out') opt.out = argv[++i];
  else if (a === '--pages') opt.pages = argv[++i];
  else if (a === '--viewports') opt.viewports = argv[++i];
  else if (a === '--setup') opt.setup = argv[++i];
  else if (a === '--no-fullpage') opt.fullpage = false;
  else if (a === '--settle') opt.settle = Number(argv[++i]);
  else if (a === '--concurrency') opt.concurrency = Number(argv[++i]);
  else if (a === '--allow-identical') opt.allowIdentical = true;
  else die(64, `unknown arg: ${a}\nusage: capture.mjs --pages <pages.json|JSON> [--base URL] [--out DIR] [--viewports ...] [--setup ./qa-setup.mjs]`);
}
if (!opt.pages) die(64, 'usage: capture.mjs --pages <pages.json|JSON> [--base URL] [--out DIR] [--viewports ...] [--setup ./qa-setup.mjs]');

let pages;
try {
  pages = JSON.parse(opt.pages.trim().startsWith('[') ? opt.pages : readFileSync(opt.pages, 'utf8'));
} catch (e) { die(64, `--pages 해석 실패: ${e.message}`); }
if (!Array.isArray(pages) || pages.length === 0 || !pages.every((p) => p.key && typeof p.path === 'string'))
  die(64, '--pages는 비어있지 않은 [{key, path}] 배열이어야 함');

let setupFn = null;
if (opt.setup) {
  const abs = path.resolve(process.cwd(), opt.setup);
  try {
    const mod = await import(pathToFileURL(abs).href);
    setupFn = mod.default ?? mod.setup;
  } catch (e) { die(64, `--setup 로드 실패(${abs}): ${e.message}`); }
  if (typeof setupFn !== 'function') die(64, `--setup은 async 함수를 default export 해야 함: ${abs}`);
}

const PRESETS = {
  'mobile-390': { width: 390, height: 844 },
  'tablet-768': { width: 768, height: 1024 },
  'desktop-1440': { width: 1440, height: 900 },
};
const viewports = opt.viewports.split(',').map((v) => {
  v = v.trim();
  if (PRESETS[v]) return { key: v, ...PRESETS[v] };
  const m = v.match(/^(\d+)x(\d+)$/);
  if (m) return { key: v, width: +m[1], height: +m[2] };
  die(64, `viewport 해석 불가: ${v} (프리셋 ${Object.keys(PRESETS).join('/')} 또는 WxH)`);
});

// 상주 워크로드(dev server·빌드·다른 세션)에 양보 — 캡처는 배치성이라 자기 우선순위를 낮춘다(root 불필요).
try { os.setPriority(10); } catch { /* 비지원 플랫폼 무시 */ }

// 부하 적응 동시성(뷰포트 컨텍스트 단위) — 명시 --concurrency가 우선.
function autoConcurrency() {
  try {
    const ratio = os.loadavg()[0] / os.cpus().length;
    return ratio >= 3 ? 1 : ratio >= 1.5 ? 2 : 3;
  } catch { return 2; }
}
const conc = opt.concurrency > 0 ? opt.concurrency : autoConcurrency();

// playwright는 실행한 프로젝트의 것을 쓴다(이 파일의 위치가 아니라 cwd 기준 해석).
let chromium;
try {
  ({ chromium } = createRequire(path.join(process.cwd(), 'noop.js'))('playwright'));
} catch {
  die(69, 'playwright 모듈을 cwd 기준으로 찾지 못함 — 프로젝트 루트에서 실행하거나 `npm i -D playwright`.');
}

// 픽셀-중립 결정성: 애니메이션·트랜지션·캐럿 고정(시각 회귀 표준 관행 — 렌더 결과 자체는 불변).
const FREEZE_CSS = '*,*::before,*::after{animation-duration:0s!important;animation-delay:0s!important;'
  + 'transition-duration:0s!important;transition-delay:0s!important;caret-color:transparent!important;'
  + 'scroll-behavior:auto!important}';
// 렌더에 관여하지 않는 트래커만 차단(짧은 고신뢰 목록 — 앱 리소스는 절대 차단 안 함).
const TRACKERS = /google-analytics\.com|googletagmanager\.com|sentry\.io|hotjar\.com|segment\.(io|com)|clarity\.ms|doubleclick\.net/;
// 인증 고착 감지용 — 최종 URL이 여기 걸리면 '로그인 화면에 갇힘'으로 본다.
const AUTH_PATH = /\/(login|signin|sign-in|auth|accounts\/login)(\/|\?|$)/i;

// do 스텝 실행 — 정지 캡처가 구조적으로 못 보는 '상태'를 만든다.
async function runSteps(page, steps) {
  for (const s of steps) {
    if (s.click)        await page.locator(s.click).first().click({ timeout: 10_000 });
    else if (s.fill)    await page.locator(s.fill).first().fill(String(s.value ?? ''), { timeout: 10_000 });
    else if (s.select)  await page.locator(s.select).first().selectOption(String(s.value ?? ''), { timeout: 10_000 });
    else if (s.hover)   await page.locator(s.hover).first().hover({ timeout: 10_000 });
    else if (s.waitFor) await page.locator(s.waitFor).first().waitFor({ timeout: 15_000 });
    else if (s.press)   await page.keyboard.press(s.press);
    else if (s.scroll !== undefined) {
      const to = s.scroll === 'bottom' ? 'document.body.scrollHeight' : s.scroll === 'top' ? '0' : String(Number(s.scroll) || 0);
      await page.evaluate(`window.scrollTo(0, ${to})`);
    }
    else if (s.offline !== undefined) await page.context().setOffline(!!s.offline);
    else if (s.emulate) await page.emulateMedia({ media: s.emulate });
    else if (s.wait)    await page.waitForTimeout(Number(s.wait));
    else throw new Error(`알 수 없는 do 스텝: ${JSON.stringify(s)}`);
  }
}

mkdirSync(opt.out, { recursive: true });
console.log(`capture: ${pages.length}p × ${viewports.length}vp → ${opt.out}/ `
  + `(base=${opt.base}, concurrency=${conc}, nice=10, setup=${opt.setup ?? '없음'})`);
const browser = await chromium.launch({ args: ['--disable-dev-shm-usage', '--disable-gpu'] });
const t0 = Date.now();
let shot = 0;
const failed = [];
const manifest = [];

async function captureViewport(vp) {
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    reducedMotion: 'reduce',
  });
  await context.route('**/*', (route) =>
    TRACKERS.test(route.request().url()) ? route.abort() : route.continue());
  const page = await context.newPage();

  const consoleErrors = [];
  const failedReqs = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 300)); });
  page.on('requestfailed', (r) => failedReqs.push(`${r.method()} ${r.url()} :: ${r.failure()?.errorText}`));
  page.on('response', (r) => { if (r.status() >= 400) failedReqs.push(`${r.status()} ${r.url()}`); });

  if (setupFn) {
    try {
      await setupFn(page, { base: opt.base, viewport: vp });
    } catch (e) {
      failed.push(`setup(${vp.key}): ${String(e.message).split('\n')[0]}`);
      await context.close();
      return;
    }
  }

  for (const p of pages) {
    const dest = path.join(opt.out, `${p.key}--${vp.key}.png`);
    consoleErrors.length = 0;
    failedReqs.length = 0;
    try {
      await page.goto(opt.base + p.path, { waitUntil: 'load', timeout: 90_000 });
      // SPA는 load 이후에 데이터를 가져온다 — 짧게 정착을 기다리되 실패해도 진행(픽셀-중립).
      await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});
      await page.addStyleTag({ content: FREEZE_CSS });
      await page.evaluate(() => document.fonts?.ready);
      await page.waitForTimeout(p.settle ?? opt.settle);
      if (Array.isArray(p.do) && p.do.length) {
        await runSteps(page, p.do);
        await page.waitForTimeout(p.settle ?? opt.settle);
      }
      await page.screenshot({ path: dest, fullPage: opt.fullpage });
      const buf = readFileSync(dest);
      const finalUrl = page.url();
      manifest.push({
        key: p.key, viewport: vp.key, path: p.path, finalUrl,
        redirected: !finalUrl.endsWith(p.path) && !finalUrl.includes(p.path),
        bytes: statSync(dest).size,
        sha1: createHash('sha1').update(buf).digest('hex'),
        consoleErrors: [...new Set(consoleErrors)].slice(0, 8),
        failedRequests: [...new Set(failedReqs)].slice(0, 8),
      });
      shot += 1;
    } catch (e) {
      failed.push(`${p.key}--${vp.key}: ${String(e.message).split('\n')[0]}`);
    }
  }
  await context.close();
}

const queue = [...viewports];
await Promise.all(Array.from({ length: Math.min(conc, queue.length) }, async () => {
  while (queue.length) await captureViewport(queue.shift());
}));
await browser.close();

writeFileSync(path.join(opt.out, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`capture: ${shot}/${pages.length * viewports.length} shots (${((Date.now() - t0) / 1000).toFixed(1)}s) → manifest.json`);

// --- DEGRADED 감지: "성공했는데 전부 같은 화면" 부류의 조용한 실패를 세운다 ---
let degraded = false;

// ① 같은 뷰포트 안에서 서로 다른 key가 동일 픽셀 → 라우팅 미적용·인증 리다이렉트·CORS 전면차단 등.
for (const vp of viewports) {
  const rows = manifest.filter((m) => m.viewport === vp.key);
  const byHash = new Map();
  for (const m of rows) byHash.set(m.sha1, [...(byHash.get(m.sha1) ?? []), m.key]);
  for (const [, keys] of byHash) {
    if (keys.length > 1) {
      degraded = true;
      console.error(`DEGRADED [${vp.key}] 서로 다른 페이지 ${keys.length}개가 동일 픽셀: ${keys.join(', ')}`);
    }
  }
}

// ② 로그인 화면 고착 — 인증 앱을 --setup 없이 캡처한 전형적 사고.
const authStuck = manifest.filter((m) => AUTH_PATH.test(m.finalUrl));
if (authStuck.length > manifest.length / 2) {
  degraded = true;
  console.error(`DEGRADED 샷 ${authStuck.length}/${manifest.length}이 로그인 화면으로 리다이렉트됨 — `
    + `인증 뒤 앱이면 --setup 로그인 훅이 필요하다.`);
}

// ③ 리다이렉트된 경로(죽은 메뉴 후보) — 실패는 아니지만 판독 전에 알아야 한다.
const redirected = manifest.filter((m) => m.redirected && !AUTH_PATH.test(m.finalUrl));
if (redirected.length) {
  console.error(`주의: 요청 경로와 최종 URL이 다른 샷 ${redirected.length}건 — `
    + [...new Set(redirected.map((m) => `${m.path} → ${new URL(m.finalUrl).pathname}`))].join(', '));
}

if (failed.length) {
  console.error(`실패 ${failed.length}건 — 부분 캡처는 DEGRADED로 보고할 것:\n  ${failed.join('\n  ')}`);
}
if (failed.length || (degraded && !opt.allowIdentical)) process.exit(3);
