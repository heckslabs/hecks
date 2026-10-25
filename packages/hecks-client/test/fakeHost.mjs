// An in-process stand-in for a host's dispatch protocol, shaped as a `fetch`
// function so a client can be pointed at it with no socket and no network.
//
// It models the CheckoutFixture domain's Event aggregate (spec/fixtures/
// rust_host/checkout_fixture): `Event.Schedule` creates a session and
// `Event.Close` closes an open one. Answers carry the same envelope the real
// host sends (instances, events, refusals), so the scenario in scenario.mjs
// passes against this fake and against a live host alike. It also answers the
// query step: `Event.Open` lists the open sessions, any other name is refused
// the way the host refuses a question its domain does not declare. Like the
// host, it keeps each single-field value object wrapped (`{ value: "x" }`,
// `{ cents: 900 }`) and answers it bare when the request says `bare: true`.

const DOMAIN = "CheckoutFixture";

// The one field each of Event's single-field value objects declares.
const SOLE_FIELD = { slug: "value", name: "value", price: "cents", capacity: "value" };

const wrap = (facts) =>
  Object.fromEntries(Object.entries(facts).map(([key, raw]) =>
    [key, key in SOLE_FIELD && (raw === null || typeof raw !== "object") ? { [SOLE_FIELD[key]]: raw } : raw]));

const unwrap = (state) =>
  Object.fromEntries(Object.entries(state).map(([key, held]) =>
    [key, key in SOLE_FIELD && held && typeof held === "object" ? held[SOLE_FIELD[key]] : held]));

// A whole answer, with every state and query row in it answered bare.
const presented = (reply) => ({
  ...reply,
  ...(reply.instances && {
    instances: Object.fromEntries(Object.entries(reply.instances).map(([key, state]) => [key, unwrap(state)])),
  }),
  ...(reply.queries && { queries: reply.queries.map((entry) => ({ ...entry, rows: entry.rows && entry.rows.map(unwrap) })) }),
});

const answer = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/**
 * @returns {{ fetch: typeof fetch, requests: object[], instances: Record<string, object> }}
 *   `requests` collects every parsed request body, in order.
 */
export function fakeHost() {
  const instances = {};
  const requests = [];

  const outcome = (refusals = []) => ({ instances: structuredClone(instances), events: [], refusals });
  const refusal = (verb, kind, error) => outcome([{ verb, kind, error }]);

  const schedule = (verb, facts) => {
    const held = wrap(structuredClone(facts));
    instances[`${DOMAIN}::Event#${held.slug?.value}`] = { ...held, status: "open" };
    return outcome();
  };

  const close = (verb, to) => {
    const key = `${DOMAIN}::Event#${to}`;
    const event = instances[key];
    if (!event) return refusal(verb, "NotFound", `no Event with slug.value "${to}"`);
    if (event.status !== "open") return refusal(verb, "GivenNotMet", "Close refused — an open session can be closed");
    event.status = "closed";
    return outcome();
  };

  const ask = (question) => {
    const short = question.replace(/^.*::/, "");
    if (short !== "Event.Open") {
      const error = `Event has no query "${short.split(".")[1]}"`;
      return { instances: {}, events: [], refusals: [{ verb: question, kind: "UnknownVerb", error }],
               queries: [{ query: question, rows: null, error }] };
    }
    const rows = Object.values(instances).filter((event) => event.status === "open").map((event) => structuredClone(event));
    return { instances: {}, events: [], refusals: [], queries: [{ query: question, rows }] };
  };

  // What a real host's preview reports: the run's first refusal as a kind, a stage and the domain's
  // words, and nothing kept.
  const KINDS = { NotFound: ["not_found", "state"], GivenNotMet: ["refused", "givens"] };
  const preview = (body) => {
    const before = structuredClone(instances);
    const reply = handle({ ...body, dry_run: undefined });
    for (const key of Object.keys(instances)) delete instances[key];
    Object.assign(instances, before);
    const [first] = reply.refusals ?? [];
    const [kind, stage] = KINDS[first?.kind] ?? ["refused", "arguments"];
    return {
      ok: !first && !reply.error,
      refusals: first ? [{ kind, stage, refusal: first.kind, message: first.error }] : [],
    };
  };

  const handle = (body) => {
    if (body.dry_run === true) return preview(body);
    if (typeof body.query === "string") return ask(body.query);
    if (body.read === true) return outcome();
    if (typeof body.verb !== "string") return { error: 'event missing "verb"' };
    if (body.verb === `${DOMAIN}::Event.Schedule`) return schedule(body.verb, body.with ?? {});
    if (body.verb === `${DOMAIN}::Event.Close`) return close(body.verb, body.to);
    return refusal(body.verb, "TypeMismatch", `unknown command "${body.verb}"`);
  };

  const fakeFetch = async (url, init = {}) => {
    if (!String(url).endsWith("/dispatch") || init.method !== "POST") return new Response("", { status: 404 });
    const body = JSON.parse(String(init.body));
    requests.push(body);
    const reply = handle(body);
    return answer(body.bare === true ? presented(reply) : reply);
  };

  return { fetch: fakeFetch, requests, instances };
}
