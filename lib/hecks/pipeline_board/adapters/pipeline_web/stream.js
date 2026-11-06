// One event stream per browser for every board page. A browser keeps at most six connections open
// to one host, and each open /api/events stream holds one of them. With a stream for each page and
// for each embedded diagram, three board tabs used all six, and every later request waited forever.
//
// So the pages share one stream: the tab holding the "board-stream" lock reads /api/events and
// passes each message to the other pages on a BroadcastChannel. It keeps the newest events and the
// last state, and hands them to a page that opens later, so that page starts as full as the first.
// When that tab closes its lock is released, and a waiting page takes the stream over.
//
// boardStream({ open, error, state, board }): `state` and `board` get each message's parsed data.
(function () {
  const KEEP = 300;

  function direct(on) {
    if (!window.EventSource) return false;
    const es = new EventSource("/api/events");
    es.onopen = () => on.open && on.open();
    es.onerror = () => on.error && on.error();
    es.addEventListener("state", (m) => on.state && on.state(JSON.parse(m.data)));
    es.addEventListener("board", (m) => on.board && on.board(JSON.parse(m.data)));
    return true;
  }

  window.boardStream = function boardStream(on) {
    if (!window.BroadcastChannel || !(navigator.locks && navigator.locks.request)) return direct(on);
    const me = Math.random().toString(36).slice(2);
    const channel = new BroadcastChannel("board-stream");
    const kept = [];
    let state = null, live = false, leading = false, joined = false;

    const deliver = (m) => {
      if (m.type === "status") return m.live ? on.open && on.open() : on.error && on.error();
      if (on[m.type]) on[m.type](m.data);
    };
    const share = (m) => {
      if (m.type === "board") { kept.push(m); if (kept.length > KEEP) kept.shift(); }
      if (m.type === "state") state = m;
      if (m.type === "status") live = m.live;
      channel.postMessage(m);
      deliver(m);
    };

    channel.onmessage = ({ data: m }) => {
      if (m.type === "hello") {
        if (leading) channel.postMessage({ type: "replay", to: m.from, live, items: state ? [...kept, state] : kept.slice() });
        return;
      }
      if (m.type === "replay") {
        if (m.to !== me || joined) return;
        joined = true;
        m.items.forEach(deliver);
        return deliver({ type: "status", live: m.live });
      }
      if (leading) return;
      if (m.type === "board") { kept.push(m); if (kept.length > KEEP) kept.shift(); }
      if (m.type === "state") state = m;
      if (m.type === "status") live = m.live;
      deliver(m);
    };

    // Ask whoever holds the stream for what it has kept; then wait for the lock, in case it closes.
    channel.postMessage({ type: "hello", from: me });
    navigator.locks.request("board-stream", () => new Promise(() => {
      leading = true;
      joined = true;
      const es = new EventSource("/api/events");
      es.onopen = () => share({ type: "status", live: true });
      es.onerror = () => share({ type: "status", live: false });
      es.addEventListener("state", (m) => share({ type: "state", data: JSON.parse(m.data) }));
      es.addEventListener("board", (m) => share({ type: "board", data: JSON.parse(m.data) }));
    }));
    return true;
  };
})();
