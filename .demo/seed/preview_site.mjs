// A tiny stand-in for the public Marlow & Finch site, so the editor's preview drawer has a page to show.
// It reads posts, pages and their text from the host and renders them with the editor's own body renderer.
import { createServer } from "node:http";
import { bodyToHtml, esc } from "../editor/src/ui/body_model.js";

const HOST = process.env.HOST_URL ?? "http://127.0.0.1:48410";
const PORT = Number(process.env.PORT ?? 48430);
const EDITOR = process.env.EDITOR_URL ?? "http://127.0.0.1:48420";

async function read() {
  const res = await fetch(`${HOST}/dispatch`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ read: true }) });
  return res.json();
}
const find = (answer, aggregate, id) => Object.entries(answer.state ?? answer.instances ?? {}).find(([k]) => k.endsWith(`${aggregate}#${id}`))?.[1];

const html = (title, inner) => `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>${esc(title)} | Marlow &amp; Finch</title>
<style>
body{margin:0;font:18px/1.65 Georgia,serif;color:#1d2a2e;background:#fbf8f3}
header{padding:18px 24px;border-bottom:1px solid #e3dccf;font:600 15px system-ui;letter-spacing:.04em;display:flex;gap:20px;align-items:baseline}
header b{font-size:18px}main{max-width:40rem;margin:0 auto;padding:32px 24px 64px}
h1{font:700 2.1rem/1.15 Georgia,serif;margin:.2em 0 .5em}h2{font-size:1.4rem;margin-top:1.8em}
img,figure{max-width:100%}figure{margin:1.5em 0}figcaption{font:14px system-ui;color:#5b6a6e}
blockquote{border-left:4px solid #0f766e;margin:1.5em 0;padding-left:1em;font-style:italic}a{color:#0f766e}
.flag{font:12px system-ui;background:#fde68a;color:#78350f;padding:2px 8px;border-radius:99px}
</style><header><b>Marlow &amp; Finch</b><span>Work</span><span>Journal</span><span>About</span><span>Contact</span></header><main>${inner}</main>`;

function render(body) {
  // images: the domain keeps a picture key; the editor serves the bytes
  return bodyToHtml(body).replace(/<figure([^>]*)data-media-ref="([^"]*)"([^>]*)>[\s\S]*?<\/figure>/g, (m, a, key, b) => {
    const alt = (m.match(/data-alt="([^"]*)"/) ?? [])[1] ?? "";
    const cap = (m.match(/data-caption="([^"]*)"/) ?? [])[1];
    return `<figure><img src="${EDITOR}/editor/media/${key}" alt="${alt}">${cap ? `<figcaption>${cap}</figcaption>` : ""}</figure>`;
  });
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const [, kind, slug] = url.pathname.split("/");
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Content-Security-Policy", `frame-ancestors ${EDITOR}`);
  try {
    if (!slug) return res.end(html("Marlow & Finch", "<h1>Marlow &amp; Finch</h1><p>Open a post from the editor to preview it here.</p>"));
    const answer = await read();
    const record = find(answer, kind === "post" ? "Post" : "Page", slug);
    const doc = find(answer, "Document", `${kind}:${slug}`);
    if (!record) { res.statusCode = 404; return res.end(html("Not found", "<h1>Not found</h1>")); }
    const showDraft = url.searchParams.get("preview") && doc?.draft_body;
    const flag = showDraft ? ` <span class="flag">working copy</span>` : record.status && record.status !== "published" ? ` <span class="flag">${esc(record.status)}</span>` : "";
    res.end(html(record.title.value, `<h1>${esc(record.title.value)}${flag}</h1>${render(showDraft ? doc.draft_body : doc?.body)}`));
  } catch (e) { res.statusCode = 500; res.end(html("Error", `<p>${esc(e)}</p>`)); }
}).listen(PORT, "127.0.0.1", () => console.log("preview site on", PORT));
