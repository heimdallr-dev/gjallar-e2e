// Browser checks for the interactive Keycloak flows, run inside the cluster
// (so keycloak.keycloak.svc resolves and the token issuer matches):
//   1. Web UI: Authorization Code + PKCE login, then the UI calls the API.
//   2. CLI: `gjallar login` device flow, approved on Keycloak's page.
// See browser/run-in-kind.sh. Env: WEB, ISSUER, API, GJALLAR_BIN, users.
import { chromium } from "playwright";
import { spawn } from "node:child_process";

const WEB = process.env.WEB ?? "http://gjallar-web.gjallar.svc:8083";
const ISSUER = process.env.ISSUER ?? "http://keycloak.keycloak.svc:8080/realms/gjallar";
const API = process.env.API ?? "http://gjallar-api.gjallar.svc:8080";
const BIN = process.env.GJALLAR_BIN ?? "/work/gjallar";
const [ADMIN, ADMIN_PW] = (process.env.ADMIN ?? "admin:test-admin").split(":");
const [VIEWER, VIEWER_PW] = (process.env.VIEWER ?? "viewer:test-viewer").split(":");
const OUT = process.env.OUT ?? "/work/out";

const fail = (msg) => { console.error("FAIL", msg); process.exit(1); };
const ok = (msg) => console.log("PASS", msg);

async function keycloakLogin(page, user, pw) {
  await page.waitForSelector("#username", { timeout: 30000 });
  await page.fill("#username", user);
  await page.fill("#password", pw);
  await page.click("#kc-login");
}

const browser = await chromium.launch({
  // http:// in-cluster origin: let WebCrypto (PKCE) run as it would behind HTTPS.
  args: [`--unsafely-treat-insecure-origin-as-secure=${new URL(WEB).origin}`],
});

// ---- 1. Web UI PKCE -----------------------------------------------------
{
  const page = await (await browser.newContext()).newPage();
  page.on("console", (m) => m.type() === "error" && console.log("browser console:", m.text()));
  page.on("pageerror", (e) => console.log("page error:", e.message));
  page.on("requestfailed", (r) => console.log("request failed:", r.url(), r.failure()?.errorText));
  await page.goto(WEB);
  await page.click("#login", { timeout: 30000 }).catch(async (e) => {
    await page.screenshot({ path: `${OUT}/web-boot-failed.png`, fullPage: true });
    fail(`no Sign in button: ${(await page.content()).slice(0, 600)}`);
  });
  if (!page.url().startsWith(ISSUER)) fail(`not redirected to Keycloak: ${page.url()}`);
  if (!page.url().includes("code_challenge_method=S256")) fail("authorize request without PKCE S256");
  await keycloakLogin(page, ADMIN, ADMIN_PW);
  await page.waitForURL((u) => u.toString().startsWith(WEB), { timeout: 30000 });
  await page.waitForFunction(() => document.querySelector("#who")?.textContent.includes("admin"), null, { timeout: 30000 });
  const err = await page.locator("#view .err").count();
  await page.screenshot({ path: `${OUT}/web-signed-in.png`, fullPage: true });
  if (err) fail("UI shows an error panel after login");
  const stored = await page.evaluate(() => Object.keys(sessionStorage).length);
  const persisted = await page.evaluate(() => Object.keys(localStorage).length);
  ok(`web PKCE login as ${ADMIN}; UI loaded data; token in sessionStorage (${stored} keys), localStorage keys: ${persisted}`);
  await page.click("#logout");
  await page.waitForSelector("#login", { timeout: 30000 });
  ok("web sign out returns to the Sign in screen");
}

// ---- 2. CLI device flow ---------------------------------------------------
{
  const cli = spawn(BIN, ["login", ISSUER], { env: { ...process.env, HOME: "/tmp/cli-home" } });
  let out = "";
  const link = await new Promise((resolve, reject) => {
    cli.stdout.on("data", (d) => { out += d; const m = out.match(/Open (\S+)/); if (m) resolve(m[1]); });
    cli.stderr.on("data", (d) => (out += d));
    cli.on("exit", (c) => reject(new Error(`gjallar login exited ${c}: ${out}`)));
    setTimeout(() => reject(new Error(`no link from gjallar login: ${out}`)), 30000);
  });
  const page = await (await browser.newContext()).newPage();
  await page.goto(link);
  if (await page.locator("#device-user-code").count()) {
    await page.fill("#device-user-code", out.match(/code (\S+)/)[1]);
    await page.click("input[type=submit], #kc-login");
  }
  await keycloakLogin(page, VIEWER, VIEWER_PW);
  const grant = page.locator("#kc-login, input[name=accept], button:has-text('Yes')");
  if (await grant.first().isVisible({ timeout: 10000 }).catch(() => false)) await grant.first().click();
  await page.waitForSelector("text=/success|device.*(log|sign)ged in|you may close/i", { timeout: 30000 })
    .catch(() => {}); // wording differs between Keycloak versions; the CLI result is what counts
  await page.screenshot({ path: `${OUT}/device-approved.png`, fullPage: true });
  const code = await new Promise((r) => (cli.exitCode !== null ? r(cli.exitCode) : cli.on("exit", r)));
  if (code !== 0) fail(`gjallar login exit ${code}: ${out}`);
  ok("CLI device flow: code approved in the browser, gjallar login succeeded");

  const me = spawn(BIN, ["summary"], { env: { ...process.env, HOME: "/tmp/cli-home", GJALLAR_URL: API } });
  let s = ""; me.stdout.on("data", (d) => (s += d)); me.stderr.on("data", (d) => (s += d));
  const rc = await new Promise((r) => me.on("exit", r));
  if (rc !== 0 || !s.includes("open_findings")) fail(`gjallar summary with cached token: ${rc} ${s.slice(0, 300)}`);
  ok("CLI uses the cached device-flow token: gjallar summary works as viewer");
}

await browser.close();
