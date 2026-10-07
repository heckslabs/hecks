// A stand-in for the domain host, for running a generated editor against the newsroom fixture
// (spec/fixtures/site/editor_workflow) under node and in a browser. It answers `/members` and the
// body-shaped `/dispatch` (read, query, command), keeping the instances in memory, and it reads the
// editor's own schema for what a command does: a creating command makes a record, a lifecycle move
// changes the status, the draft commands move or drop the draft body, and any other command on a
// record writes the arguments it was given. It checks nothing a real domain would; it is only as
// faithful as the editor needs to see the answers change.
//
// It can be told to refuse the next dispatch of a verb once (`refuseNext`), to show the editor's
// handling of a failed save.

export const members = [{ email: "ed@example.org", role: "Admin" }, { email: "own@example.org", role: "Owner" }];

const value = (text) => ({ value: text });

/** A paragraph body, as the domain holds one. */
export const paragraphs = (...texts) => ({
  blocks: texts.map((text) => ({ kind: "paragraph", spans: [{ text, marks: [] }], items: [] })),
});

/** The records the fixture starts with, keyed as the host answers them. */
export function seed(now) {
  const day = 86_400;
  return {
    "Publishing::Post#first-light": { slug: value("first-light"), title: value("First light"), status: "published" },
    "Publishing::Post#second-wind": { slug: value("second-wind"), title: value("Second wind"), status: "draft" },
    "Publishing::Page#about": { slug: value("about"), title: value("About us") },
    "Documents::Document#post:first-light": { key: value("post:first-light"), body: paragraphs("The first post says hello.", "It has two paragraphs.") },
    "Pictures::MediaItem#aa.png": { key: value("aa.png"), alt: value("A red door"), mime_type: value("image/png") },
    "Pictures::MediaItem#bb.png": { key: value("bb.png"), alt: value("A blue gate"), mime_type: value("image/png") },
    "Schedule::ScheduledAction#a1": action("a1", "post:second-wind", "publish", now + 2 * day, "pending"),
    "Schedule::ScheduledAction#a2": action("a2", "post:first-light", "publish", now - 3 * day, "done"),
    "Schedule::ScheduledAction#a3": { ...action("a3", "post:first-light", "withdraw", now - day, "failed"), reason: value("The site did not answer.") },
  };
}

function action(id, subject, name, due, status) {
  return { id: value(id), subject: value(subject), action: value(name), due_at: value(due), status };
}

/** The draft becomes the live body and the draft is gone. */
function promote(state, drafts) {
  state[drafts.live] = state[drafts.attribute];
  delete state[drafts.attribute];
}

const leaf = (item) => (item && typeof item === "object" ? leaf(Object.values(item)[0]) : item);

/**
 * @param {{ aggregates: object[] }} schema the editor's schema
 * @param {object} [options]
 * @param {Record<string, object>} [options.instances] the records to start with
 * @returns {{ fetch: typeof fetch, instances: object, sent: object[], refuseNext(verb: string, message?: string): void }}
 */
export function standInHost(schema, { instances = {} } = {}) {
  const sent = [];
  const refusals = new Map();
  const find = (qualified) => {
    const [chapter, rest] = qualified.includes("::") ? qualified.split("::") : [undefined, qualified];
    const [name] = rest.split(".");
    return schema.aggregates.find((agg) => agg.name === name && (!chapter || agg.chapter === chapter || !agg.chapter));
  };
  const hostName = (agg) => `${agg.chapter ?? schema.domain}::${agg.name}`;
  const answer = (extra = {}) => ({ ok: true, status: 200, json: async () => ({ instances: structuredClone(instances), refusals: [], ...extra }) });
  const rowsOf = (agg) => Object.entries(instances).filter(([id]) => id.startsWith(`${hostName(agg)}#`)).map(([, row]) => row);

  const ask = (body) => {
    const agg = find(body.query);
    const query = body.query.split(".")[1];
    const arg = Object.entries(body.args ?? {});
    const rows = rowsOf(agg).filter((row) => arg.every(([name, given]) => leaf(row[name]) === leaf(given)));
    return answer({ queries: [{ query: body.query, args: body.args, rows }], asked: query });
  };

  const run = (body) => {
    const agg = find(body.verb);
    const command = agg.commands.find((candidate) => candidate.name === body.verb.split(".")[1]);
    const refusal = refusals.get(command.name);
    if (refusal !== undefined) {
      refusals.delete(command.name);
      return answer({ refusals: [{ verb: body.verb, kind: "GivenNotMet", error: `${command.name} refused — ${refusal}` }] });
    }
    if (body.to) apply(agg, command, `${hostName(agg)}#${body.to}`, body.with ?? {});
    else make(agg, body.with ?? {});
    return answer();
  };

  const make = (agg, given) => {
    const state = { ...given, ...(agg.lifecycle ? { [agg.lifecycle.field]: agg.lifecycle.default } : {}) };
    instances[`${hostName(agg)}#${leaf(given[agg.identity])}`] = state;
  };

  const apply = (agg, command, key, given) => {
    const state = instances[key];
    const drafts = agg.drafts;
    const move = agg.lifecycle?.transitions.find((transition) => transition.verb === command.name);
    if (move) state[agg.lifecycle.field] = move.to;
    else if (drafts?.publish === command.name) promote(state, drafts);
    else if (drafts?.discard === command.name) delete state[drafts.attribute];
    else Object.assign(state, given);
  };

  const fetch = async (url, init) => {
    if (new URL(url).pathname === "/members") return { ok: true, status: 200, json: async () => members };
    const body = JSON.parse(init.body);
    sent.push(body);
    if (body.read) return answer();
    return body.query ? ask(body) : run(body);
  };

  return { fetch, instances, sent, refuseNext: (verb, message = "an edit is saved") => refusals.set(verb, message) };
}
