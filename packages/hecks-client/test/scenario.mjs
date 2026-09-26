// One walk through the protocol, written against any `HostClient` whose host
// serves the CheckoutFixture domain. The hermetic tests run it against the
// in-process fake (fakeHost.mjs); contract.mjs runs the same walk against a
// live host, so the two cannot drift apart unnoticed.

import assert from "node:assert/strict";

import { DomainRefusal, refusalOf, text, whole } from "../dist/index.js";

const eventsFrom = (client, answer) =>
  client.instancesOf(answer, "Event").map(([slug, state]) => ({
    slug,
    name: text(state.name),
    priceCents: whole(state.price, "cents"),
    capacity: whole(state.capacity, "value"),
    status: state.status,
  }));

/** @param {import("../dist/index.js").HostClient} client */
export async function runEventScenario(client, slug = `session-${Date.now()}`) {
  const before = await client.read();
  assert.deepEqual(client.instancesOf(before, "Event").filter(([id]) => id === slug), [], "the session does not exist yet");

  const scheduled = await client.apply({
    verb: "Event.Schedule",
    with: { slug: { value: slug }, name: { value: "Yoga" }, price: { cents: 10800 }, capacity: { value: 12 } },
    parse: (answer) => eventsFrom(client, answer),
    confirm: (events) => events.some((event) => event.slug === slug),
  });
  assert.deepEqual(scheduled.find((event) => event.slug === slug), { slug, name: "Yoga", priceCents: 10800, capacity: 12, status: "open" });

  const closed = await client.apply({
    verb: "Event.Close",
    to: slug,
    with: {},
    parse: (answer) => eventsFrom(client, answer),
    confirm: (events) => events.find((event) => event.slug === slug)?.status === "closed",
  });
  assert.equal(closed.find((event) => event.slug === slug)?.status, "closed");

  // A second Close changes nothing; the domain says why, and refusalOf carries its words.
  const again = await client.dispatch("Event.Close", {}, slug);
  const refusal = refusalOf(again, "Event.Close");
  assert.ok(refusal instanceof DomainRefusal);
  assert.equal(refusal.kind, "GivenNotMet");
  assert.match(refusal.message, /an open session can be closed/);

  // A command aimed at nothing turns into a refusal when the state does not show the change.
  await assert.rejects(
    client.apply({
      verb: "Event.Close",
      to: `${slug}-missing`,
      with: {},
      parse: (answer) => eventsFrom(client, answer),
      confirm: (events) => events.find((event) => event.slug === `${slug}-missing`)?.status === "closed",
    }),
    (err) => err instanceof DomainRefusal && err.kind === "NotFound",
  );

  const after = await client.read();
  assert.equal(eventsFrom(client, after).find((event) => event.slug === slug)?.status, "closed");
}
