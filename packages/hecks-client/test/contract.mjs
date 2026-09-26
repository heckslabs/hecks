// Runs the client's protocol scenario against a live host (rust/host started
// with HECKS_SERVE_MODE=1, serving the checkout fixture domain), so a change
// to either side that breaks the wire shape fails here.
//
//   HECKS_SERVICE_URL=http://127.0.0.1:8080 node test/contract.mjs
//
// HECKS_DOMAIN names the domain the host serves and defaults to
// CheckoutFixture, the fixture the scenario is written against
// (spec/fixtures/rust_host/checkout_fixture). Each run schedules its own
// uniquely named session, so it can be repeated against the same database.
// The wait for the host to start is bounded by HECKS_CONTRACT_WAIT_SECONDS
// (default 60).

import assert from "node:assert/strict";
import { before, describe, it } from "node:test";

import { DomainUnavailable, HostClient } from "../dist/index.js";
import { runEventScenario } from "./scenario.mjs";

const url = process.env.HECKS_SERVICE_URL;
if (!url) {
  console.error("HECKS_SERVICE_URL is required: the base URL of a host started with HECKS_SERVE_MODE=1");
  process.exit(2);
}
const domain = process.env.HECKS_DOMAIN || "CheckoutFixture";
const waitSeconds = Number(process.env.HECKS_CONTRACT_WAIT_SECONDS || 60);

const client = new HostClient({ domain, url, role: "Organizer" });

// The health route answers as soon as the server listens, but the scenario
// needs the domain booted, so poll the protocol's own read.
async function waitForHost() {
  const deadline = Date.now() + waitSeconds * 1000;
  for (;;) {
    try {
      await client.read();
      return;
    } catch (err) {
      if (Date.now() > deadline) throw err;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
}

describe(`the live host at ${url}`, () => {
  before(waitForHost);

  it("walks the shared protocol scenario", async () => {
    await runEventScenario(client);
  });

  it("answers a read with the protocol envelope", async () => {
    const answer = await client.read();
    assert.equal(typeof answer.instances, "object");
    assert.ok(Array.isArray(answer.refusals));
  });

  it("refuses a command the domain does not declare, in the domain's own words", async () => {
    const answer = await client.dispatch("Event.NotACommand", {});
    assert.ok(answer.refusals.length > 0);
    assert.equal(typeof answer.refusals.at(-1).kind, "string");
  });

  it("reports a host that is not listening as unavailable", async () => {
    const nobody = new HostClient({ domain, url: "http://127.0.0.1:1", timeoutMs: 2000 });
    await assert.rejects(nobody.read(), DomainUnavailable);
  });
});
