#!/usr/bin/env node
/**
 * Login-flow smoke check for fhe-scoreboard.
 *
 * This app is a single-page app that keeps its session in sessionStorage
 * (not cookies/localStorage), so the shared /smoke skill's headless runner
 * can't verify it — that runner hands off between a login context and a
 * fresh route-check context via Playwright's storageState(), which does not
 * capture sessionStorage. This script instead runs each named login flow
 * start-to-finish in a single page/context, so the app's in-memory +
 * sessionStorage auth state stays intact through the final screenshot.
 *
 * Read-only: agentLogin()/adminLogin() only call verify_agent_login /
 * verify_admin_login RPCs — no writes, no lockouts, no shared session state.
 *
 * Usage:
 *   node scripts/smoke-login-check.mjs loginAgent
 *   node scripts/smoke-login-check.mjs loginAdmin
 */
import { readFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { homedir } from "node:os";

// This project has no local Node deps of its own (plain static HTML app) —
// reuse the Playwright install already bundled with the /smoke skill.
const playwright = await import(join(homedir(), ".claude/skills/smoke/node_modules/playwright/index.js"));
const chromium = playwright.chromium || playwright.default.chromium;

const flowName = process.argv[2];
if (!flowName) {
  console.error("Usage: node smoke-login-check.mjs <flowName>");
  process.exit(2);
}

const config = JSON.parse(readFileSync(resolve("smoke.config.json"), "utf8"));
const baseUrl = config.baseUrl.replace(/\/$/, "");
const flow = config.flows?.[flowName];
if (!flow) {
  console.error(`No flow named "${flowName}" in smoke.config.json`);
  process.exit(2);
}

const outDir = resolve(".smoke-out");
mkdirSync(outDir, { recursive: true });
const timeout = config.defaultTimeout || 15000;

function resolveEnv(value) {
  if (typeof value !== "string" || !value.startsWith("$")) return value;
  const name = value.slice(1);
  const v = process.env[name];
  if (v === undefined || v === "") {
    console.error(`Missing env var ${name} (referenced in flows.${flowName})`);
    process.exit(2);
  }
  return v;
}

const consoleErrors = [];
const failedRequests = [];

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
page.on("console", (msg) => { if (msg.type() === "error") consoleErrors.push(msg.text().slice(0, 300)); });
page.on("pageerror", (err) => consoleErrors.push(`pageerror: ${err.message}`.slice(0, 300)));
page.on("response", (resp) => {
  if (resp.status() >= 400) failedRequests.push(`${resp.status()} ${resp.url().slice(0, 160)}`);
});

let failure = null;
try {
  for (const step of flow) {
    switch (step.action) {
      case "navigate":
        await page.goto(baseUrl + step.path, { waitUntil: "domcontentloaded", timeout });
        break;
      case "fill":
        await page.locator(step.selector).fill(resolveEnv(step.value), { timeout });
        break;
      case "click":
        await page.locator(step.selector).click({ timeout });
        break;
      case "waitFor":
        await page.locator(step.selector).waitFor({ timeout: step.timeout || timeout });
        break;
      case "wait":
        await page.waitForTimeout(step.duration || 1000);
        break;
      case "screenshot":
        await page.screenshot({ path: join(outDir, `${step.name}.png`), fullPage: true });
        break;
      default:
        console.error(`Unknown step action: ${step.action}`);
    }
  }
} catch (err) {
  failure = err.message;
  await page.screenshot({ path: join(outDir, `${flowName}-failure.png`) }).catch(() => {});
}

await browser.close();

const pass = !failure && consoleErrors.length === 0 && failedRequests.length === 0;
console.log(JSON.stringify({ flow: flowName, pass, failure, consoleErrors, failedRequests, outDir }, null, 2));
process.exit(pass ? 0 : 1);
