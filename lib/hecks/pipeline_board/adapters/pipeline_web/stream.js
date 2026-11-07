// One event stream per browser for every board page, and none while no board page is in view.
//
// A browser keeps at most six connections open to one host, and each open /api/events stream holds
// one of them. With a stream for each page and each embedded diagram, three board tabs used all six
// and every later request waited forever. So the pages share one stream: the visible page holding
// the "board-stream" lock reads /api/events and passes each message to the others on a
// BroadcastChannel. It keeps the newest events and the last state and hands them to a page that
// joins later, so that page starts as full as the first.
//
// A hidden page (a background tab, a minimised window) does not hold or wait for the stream. When
// the page holding it is hidden it lets go, and another visible board page takes it; when none is
// visible the connection is closed. A page shown again asks for the stream back, and the server
// sends a new reader the current state and the recent events, so nothing is missed.
//
// boardStream({ open, error, pause, state, board, wiring }): `state`, `board` and `wiring` get each
// message's data. A `wiring` message ({ digest }) says the bluebooks are drawn differently; a
// diagram page that holds another digest fetches /api/wiring again and redraws.
(function () {
  const KEEP = 300;
  const visible = () => document.visibilityState === "visible";

  // Opens /api/events and passes each message on as { type, data } or { type: "status" }.
  function connect(emit) {
    const es = new EventSource("/api/events");
    es.onopen = () => emit({ type: "status", live: true });
    es.onerror = () => emit({ type: "status", live: false });
    es.addEventListener("state", (m) => emit({ type: "state", data: JSON.parse(m.data) }));
    es.addEventListener("board", (m) => emit({ type: "board", data: JSON.parse(m.data) }));
    es.addEventListener("wiring", (m) => emit({ type: "wiring", data: JSON.parse(m.data).wiring }));
    return es;
  }

  window.boardStream = function boardStream(on) {
    if (!window.EventSource) return false;
    const deliver = (m) => {
      if (m.type !== "status") return on[m.type] && on[m.type](m.data);
      const handler = m.paused ? on.pause : m.live ? on.open : on.error;
      if (handler) handler();
    };
    const paused = () => deliver({ type: "status", paused: true });

    // Without a channel or locks to share through, each page keeps its own stream, open only in view.
    if (!window.BroadcastChannel || !(navigator.locks && navigator.locks.request)) {
      let es = null;
      const follow = () => {
        if (visible() && !es) es = connect(deliver);
        else if (!visible() && es) { es.close(); es = null; paused(); }
      };
      document.addEventListener("visibilitychange", follow);
      follow();
      return true;
    }

    const me = Math.random().toString(36).slice(2);
    const channel = new BroadcastChannel("board-stream");
    const kept = new Map();
    let state = null, wired = null, live = false, joined = false, leading = false, waiting = null, release = null;

    const keep = (m) => {
      if (m.type === "board") {
        const key = (m.data && m.data.key) || Math.random();
        kept.delete(key); kept.set(key, m);
        if (kept.size > KEEP) kept.delete(kept.keys().next().value);
      }
      if (m.type === "state") state = m;
      if (m.type === "wiring") wired = m;
      if (m.type === "status") live = m.live;
    };
    const share = (m) => { keep(m); channel.postMessage(m); deliver(m); };

    channel.onmessage = ({ data: m }) => {
      if (m.type === "hello") {
        if (leading) channel.postMessage({ type: "replay", to: m.from, live, items: [...kept.values(), ...(state ? [state] : []), ...(wired ? [wired] : [])] });
        return;
      }
      if (m.type === "replay") {
        if (m.to !== me || joined) return;
        joined = true;
        m.items.forEach((item) => { keep(item); deliver(item); });
        return deliver({ type: "status", live: m.live });
      }
      if (leading || !visible()) return;
      keep(m);
      deliver(m);
    };

    // Waits for the stream while in view; whoever holds it reads /api/events until it is hidden.
    const lead = () => {
      if (leading || waiting) return;
      waiting = new AbortController();
      navigator.locks.request("board-stream", { signal: waiting.signal }, () => new Promise((done) => {
        waiting = null; leading = true; joined = true;
        const es = connect(share);
        release = () => { es.close(); leading = false; release = null; done(); };
      })).catch(() => {});
    };
    const follow = () => {
      if (visible()) {
        joined = leading;
        if (!joined) channel.postMessage({ type: "hello", from: me });
        return lead();
      }
      if (waiting) { waiting.abort(); waiting = null; }
      if (release) release();
      paused();
    };
    document.addEventListener("visibilitychange", follow);
    follow();
    return true;
  };
})();
