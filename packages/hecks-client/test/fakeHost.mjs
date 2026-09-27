// An in-process stand-in for a host's dispatch protocol, shaped as a `fetch`
// function so a client can be pointed at it with no socket and no network.
//
// It models the CheckoutFixture domain's Event aggregate (spec/fixtures/
// rust_host/checkout_fixture): `Event.Schedule` creates a session and
// `Event.Close` closes an open one. Answers carry the same envelope the real
// host sends (instances, events, refusals), so the scenario in scenario.mjs
// passes against this fake and against a live host alike.

const DOMAIN = "CheckoutFixture";

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
    const id = facts.slug?.value;
    instances[`${DOMAIN}::Event#${id}`] = { ...structuredClone(facts), status: "open" };
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

  const handle = (body) => {
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
    return answer(handle(body));
  };

  return { fetch: fakeFetch, requests, instances };
}
