#!/usr/bin/env node
//
// Silent-truncation canary.
//
// On 2026-08-05 the scoreboard stopped counting newly approved deals. Nothing errored,
// nothing was logged, no page broke — PostgREST had simply started capping the commission
// feed at the project's "Max rows" (1000) and returning HTTP 206 instead of an error, so
// supabase-js reported success and the board quietly added up a short list. It was found
// only because a human noticed the numbers felt wrong, days later.
//
// This checks for that class of failure directly: for every public endpoint, ask PostgREST
// how many rows actually matched (Prefer: count=exact) and compare it to how many it
// handed back. If those diverge, data is being dropped on the floor somewhere.
//
// Usage:
//   node scripts/canary.mjs            # exits 1 if anything fails
//   SLACK_WEBHOOK_URL=... node scripts/canary.mjs
//
// The Supabase URL and anon key are read out of index.html so there is exactly one place
// they are defined. The anon key is public by design — it is served to every visitor.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const html = readFileSync(join(root, "index.html"), "utf8");

const url = html.match(/https:\/\/[a-z0-9]+\.supabase\.co/)?.[0];
const key = html.match(/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.[A-Za-z0-9_.-]+/)?.[0];
if (!url || !key) {
  console.error("FATAL: could not find the Supabase URL/anon key in index.html");
  process.exit(2);
}

// Every anon-reachable read. Add new public RPCs here as they are written.
// `bounded` marks an endpoint that caps itself on purpose, so sitting at the limit is the
// designed behaviour rather than a warning sign — without it the feed would nag forever.
const ENDPOINTS = [
  ["get_public_commission_feed", {}, { bounded: true }],
  ["get_commission_stats", {}],
  ["get_scoreboard_totals", { p_since: null }],
  ["get_agent_streaks", {}],
  ["get_agents_board", {}],
  ["get_open_lines", {}],
  ["get_settled_bets_public", {}],
  ["list_admin_names", {}],
];

const failures = [];
const notes = [];

async function callRpc(fn, args) {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Prefer: "count=exact",
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
  const rows = JSON.parse(text);
  // content-range is "0-999/1018", or "*/0" when the result is empty.
  const cr = res.headers.get("content-range") ?? "";
  const total = Number(cr.split("/")[1]);
  return { rows, returned: Array.isArray(rows) ? rows.length : 1, total, status: res.status };
}

console.log(`canary → ${url}\n`);

for (const [fn, args, opts = {}] of ENDPOINTS) {
  try {
    const { returned, total, status } = await callRpc(fn, args);
    if (Number.isFinite(total) && total > returned) {
      failures.push(
        `${fn}: TRUNCATED — server matched ${total} rows but returned only ${returned} (HTTP ${status}). ` +
          `Callers aggregating this endpoint are silently working from incomplete data.`,
      );
      console.log(`  ✗ ${fn.padEnd(30)} ${returned}/${total} TRUNCATED`);
    } else {
      console.log(`  ✓ ${fn.padEnd(30)} ${returned} rows`);
      // Early warning: flag anything that has grown to within 15% of the cap, so the next
      // one gets fixed before it breaks rather than after.
      if (!opts.bounded && Number.isFinite(total) && total > 850) {
        notes.push(`${fn} is at ${total} rows — approaching the 1000-row response cap.`);
      }
    }
  } catch (e) {
    failures.push(`${fn}: request failed — ${e.message}`);
    console.log(`  ✗ ${fn.padEnd(30)} ERROR ${e.message}`);
  }
}

// Cross-check the aggregate the board actually renders against a count taken straight off
// the table by a different query path. A row count per endpoint would not catch a wrong
// GROUP BY, a join dropping rows, or a filter drifting out of sync — this does.
console.log("");
try {
  const totals = await callRpc("get_scoreboard_totals", { p_since: null });
  const stats = (await callRpc("get_commission_stats", {})).rows[0];
  const summedCount = totals.rows.reduce((s, r) => s + Number(r.sale_count), 0);
  const summedTotal = totals.rows.reduce((s, r) => s + Number(r.total), 0);
  const wantCount = Number(stats.approved_count);
  const wantTotal = Number(stats.approved_total);

  if (summedCount !== wantCount) {
    failures.push(
      `invariant: the board's per-agent sale_count sums to ${summedCount}, but the ` +
        `commissions table holds ${wantCount} approved rows. The board is counting a different set.`,
    );
    console.log(`  ✗ invariant count: board=${summedCount} vs table=${wantCount} MISMATCH`);
  } else {
    console.log(`  ✓ invariant count: board sale_count == approved rows (${wantCount})`);
  }

  if (Math.abs(summedTotal - wantTotal) > 0.005) {
    failures.push(
      `invariant: the board's per-agent totals sum to ${summedTotal}, but the commissions ` +
        `table sums to ${wantTotal}. Money on the board does not match money in the table.`,
    );
    console.log(`  ✗ invariant money: board=${summedTotal} vs table=${wantTotal} MISMATCH`);
  } else {
    console.log(`  ✓ invariant money: board totals == table sum ($${wantTotal.toLocaleString()})`);
  }
} catch (e) {
  failures.push(`invariant check failed to run — ${e.message}`);
  console.log(`  ✗ invariant: ERROR ${e.message}`);
}

for (const n of notes) console.log(`  ! ${n}`);

async function notifySlack(text) {
  const hook = process.env.SLACK_WEBHOOK_URL;
  if (!hook) {
    console.log("\n(SLACK_WEBHOOK_URL not set — not sending an alert)");
    return;
  }
  try {
    const res = await fetch(hook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    console.log(res.ok ? "\nSlack alert sent." : `\nSlack post failed: HTTP ${res.status}`);
  } catch (e) {
    console.log(`\nSlack post failed: ${e.message}`);
  }
}

if (failures.length) {
  console.log(`\n${failures.length} FAILURE(S):`);
  failures.forEach((f) => console.log(`  - ${f}`));
  await notifySlack(
    `:rotating_light: *FHE Scoreboard canary failed*\n` +
      failures.map((f) => `• ${f}`).join("\n") +
      `\n\n<https://fhe-scoreboard.vercel.app|Open the scoreboard>`,
  );
  process.exit(1);
}

console.log("\nAll checks passed.");
if (notes.length) {
  await notifySlack(
    `:warning: *FHE Scoreboard canary — heads up*\n` + notes.map((n) => `• ${n}`).join("\n"),
  );
}
