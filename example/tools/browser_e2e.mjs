// phaser-game 浏览器全链路 E2E（Phase 6 手测自动化版）
// 流程：gamepass OAuth 登录 → 选服 → 建角 → 进游戏
//       → 断线A(socket close)续接 → 断线B(黑洞 send，逼心跳超时自检)续接 → 业务无感
// 注：Chrome 的 offline 模拟（含 DevTools Offline）不会断开已建立的 WebSocket，
//     故用实例级 close / send 黑洞两种模式，分别对应「close 事件驱动」与
//     「规范义务4：心跳自检发现黑洞」两条真实断网路径。
// 用法：全链已起（account1/role1/gamepass(CALLBACK_WHITELIST=^http://localhost:3000/)/phaser-game :3000）
//       npm i playwright-core && node browser_e2e.mjs [服序号 0=s1 1=s2 2=s3，默认 s3]
//       截图与控制台日志写到当前目录 browser_e2e_shots/。
import { chromium } from 'playwright-core';
import { mkdirSync } from 'fs';

mkdirSync('browser_e2e_shots', { recursive: true });
const SHOTS = './browser_e2e_shots';
const SERVER_INDEX = Number(process.argv[2] ?? 2); // 0=s1 1=s2 2=s3
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);
const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  log(ok ? `PASS ${name}` : `FAIL ${name}`, detail);
};
const jstr = (v) => JSON.stringify(v, (k, x) => (typeof x === 'bigint' ? String(x) : x));

const browser = await chromium.launch({
  executablePath: '/usr/bin/google-chrome-stable',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});
const context = await browser.newContext({ viewport: { width: 900, height: 1150 } });

// 捕获页面创建的所有 WebSocket 实例（在 bundle 运行前打补丁）
await context.addInitScript(() => {
  window.__sockets = [];
  const RealWS = window.WebSocket;
  class PatchedWS extends RealWS {
    constructor(...args) {
      super(...args);
      window.__sockets.push(this);
    }
  }
  for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) PatchedWS[k] = RealWS[k];
  window.WebSocket = PatchedWS;
});

const page = await context.newPage();
const consoleLogs = [];
const navUrls = [];
page.on('console', (m) => consoleLogs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', (e) => consoleLogs.push(`[pageerror] ${e.message}`));
page.on('framenavigated', (f) => f === page.mainFrame() && navUrls.push(f.url()));

const clickDesign = async (dx, dy) => {
  const b = await page.evaluate(() => {
    const r = document.querySelector('canvas').getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height };
  });
  await page.mouse.click(b.left + (dx * b.width) / 768, b.top + (dy * b.height) / 1024);
};

const snap = () =>
  page.evaluate(() => {
    const s = window.networkService.client.session;
    return {
      states: window.__states.slice(),
      nonce: s.nonce != null ? String(s.nonce) : null,
      inflight: window.__inflight,
      rid: String(window.networkService.client.loginRid),
    };
  });

try {
  // ===== 1. gamepass OAuth 登录（真实表单 + 回调链）=====
  await page.goto('http://localhost:3180/auth/local?callback_url=http%3A%2F%2Flocalhost%3A3000%2F');
  await page.waitForSelector('#loginForm', { timeout: 10000 });
  await page.fill('#email', 'e2e@test.local');
  await page.fill('#password', 'pass1234');
  await page.click('button[type="submit"]');
  await page.waitForURL('http://localhost:3000/**', { timeout: 15000 });
  check(
    'OAuth 登录回调带回 token',
    navUrls.some((u) => u.startsWith('http://localhost:3000/') && u.includes('access_token=')),
    navUrls.find((u) => u.includes('access_token='))?.slice(0, 72) + '…',
  );

  // ===== 2. 等 ServerSelectScene 就绪 =====
  await page.waitForFunction(() => window.networkService?.account != null, null, { timeout: 25000 });
  await page.waitForTimeout(1500);
  const checksum = await page.evaluate(() => window.networkService.protocolChecksum);
  check('SDK 初始化 + proto checksum', checksum === '2a475e76f1a40854d145ef59903c8884', checksum);
  await page.screenshot({ path: `${SHOTS}/shot1_servers.png` });

  // ===== 3. 选服 → 建角（若无角色）=====
  await clickDesign(384, 409.6 + SERVER_INDEX * 80);
  await page.waitForFunction(
    () => document.querySelector('input') != null || window.networkService?.connected === true,
    null,
    { timeout: 20000 },
  );
  let roleName = '(已有角色直接登录)';
  if (await page.evaluate(() => document.querySelector('input') != null)) {
    roleName = 'pgweb' + Date.now().toString().slice(-6);
    await page.locator('input').fill(roleName);
    await page.screenshot({ path: `${SHOTS}/shot2_rolecreate.png` });
    await clickDesign(384, 1024 * 0.6);
    log('建角提交:', roleName);
  }

  // ===== 4. 进游戏 =====
  await page.waitForFunction(() => window.networkService?.connected === true, null, { timeout: 30000 });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${SHOTS}/shot3_game.png` });
  const rid0 = await page.evaluate(() => String(window.networkService.client.loginRid));
  check('进入 GameScene（角色登录成功）', /^\d+$/.test(rid0) && rid0 !== '0', `rid=${rid0} role=${roleName}`);

  // 状态观察钩子
  await page.evaluate(() => {
    const s = window.networkService.client.session;
    window.__states = [];
    const orig = s.opts.onState;
    s.opts.onState = (st) => {
      window.__states.push(st);
      if (orig) orig(st);
    };
    window.__inflight = 'idle';
  });

  // ===== 5A. 断线（socket close）→ 在途请求跨续接按原 id 完成 =====
  await page.evaluate(() => {
    window.__inflight = 'pending';
    window.networkService.request('role.login_info').then((r) => {
      window.__inflight = r == null ? 'null' : JSON.stringify(r, (k, v) => (typeof v === 'bigint' ? String(v) : v));
    });
    const s = window.__sockets.filter((x) => x.readyState === 1).pop();
    window.__killed = s != null;
    if (s) s.close(); // 模拟网络切断：浏览器触发 WS close 事件
  });
  check('断线注入成功（close 掉活动 WS）', await page.evaluate(() => window.__killed === true));
  await page.waitForFunction(
    () => window.__inflight !== 'pending' && window.networkService?.connected === true,
    null,
    { timeout: 30000 },
  );
  const a = await snap();
  log('A 状态序列:', jstr(a.states));
  check('A 断线被发现（offline）', a.states.includes('offline'), jstr(a.states));
  check('A 走 resume（offline 后无 relogin）', !a.states.slice(a.states.indexOf('offline')).includes('relogin'), jstr(a.states));
  check('A 在途请求按原 id 完成', a.inflight.startsWith('{') && a.inflight.includes(rid0), a.inflight.slice(0, 120));
  await page.screenshot({ path: `${SHOTS}/shot4_resumed_a.png` });
  await page.waitForTimeout(1000);

  // ===== 5B. 黑洞（send 静默丢弃、无 close 事件）→ 心跳超时自检 → 续接 =====
  const nonceB0 = (await snap()).nonce;
  await page.evaluate(() => {
    window.__states = [];
    window.__inflight = 'pending';
    const s = window.__sockets.filter((x) => x.readyState === 1).pop();
    window.__killed = s != null;
    if (s) s.send = () => {}; // 黑洞：下行发送全部丢弃，连接表面存活
    window.networkService.request('role.login_info').then((r) => {
      window.__inflight = r == null ? 'null' : JSON.stringify(r, (k, v) => (typeof v === 'bigint' ? String(v) : v));
    });
  });
  check('黑洞注入成功（send 丢弃）', await page.evaluate(() => window.__killed === true));
  log('等待心跳自检（15s×2 容差，最长约 45s）…');
  const t0 = Date.now();
  await page.waitForFunction(
    () => window.__inflight !== 'pending' && window.networkService?.connected === true && window.__states.includes('offline'),
    null,
    { timeout: 120000 },
  );
  const b = await snap();
  log(`B 状态序列: ${jstr(b.states)}（检测+续接耗时 ${((Date.now() - t0) / 1000).toFixed(1)}s）`);
  check('B 黑洞被心跳自检发现（义务4）', b.states.includes('offline'), jstr(b.states));
  check('B 走 resume（无 relogin）', !b.states.slice(b.states.indexOf('offline')).includes('relogin'), jstr(b.states));
  check('B 在途请求按原 id 完成', b.inflight.startsWith('{') && b.inflight.includes(rid0), b.inflight.slice(0, 120));
  check('B 续接凭据已轮换', nonceB0 != null && b.nonce != null && nonceB0 !== b.nonce, `${nonceB0?.slice(0, 10)}… → ${b.nonce?.slice(0, 10)}…`);
  check('B rid 一致', b.rid === rid0, `${rid0} → ${b.rid}`);
  await page.screenshot({ path: `${SHOTS}/shot5_resumed_b.png` });

  // ===== 6. 续接后业务无感 =====
  const post = await page.evaluate(async () => {
    const r = await window.networkService.getRoleLoginInfo();
    return r == null ? null : JSON.stringify(r, (k, v) => (typeof v === 'bigint' ? String(v) : v));
  });
  check('续接后新请求正常', post != null && post.includes(rid0), (post ?? 'null').slice(0, 140));
} catch (err) {
  check('流程异常', false, String(err).slice(0, 300));
  await page.screenshot({ path: `${SHOTS}/shot_error.png` }).catch(() => {});
} finally {
  const fs = await import('fs');
  fs.writeFileSync(`${SHOTS}/console.log`, consoleLogs.join('\n'));
  const pass = results.filter((r) => r.ok).length;
  log(`===== 浏览器 E2E: ${pass}/${results.length} PASS =====`);
  for (const r of results) log(`${r.ok ? '✓' : '✗'} ${r.name} ${r.detail ? '— ' + r.detail : ''}`);
  await browser.close();
  process.exit(results.every((r) => r.ok) ? 0 : 1);
}
