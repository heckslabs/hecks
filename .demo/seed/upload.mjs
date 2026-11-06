// Uploads the placeholder pictures through the editor's own media port and records the keys it made.
import { readFileSync, writeFileSync } from "node:fs";
import { accountToken } from "../editor/node_modules/@hecks/client/dist/index.js";

const EDITOR = process.env.EDITOR_URL ?? "http://127.0.0.1:48420";
const SECRET = process.env.AUTH_SECRET;
const token = accountToken(SECRET, "isla@marlowfinch.example", 600);
const sso = await fetch(`${EDITOR}/editor/api/sso?token=${token}`, { redirect: "manual" });
const cookie = sso.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
if (!cookie) throw new Error(`sign-in failed: ${sso.status}`);

const PICS = {
  "studio-desk": "The studio desk with final layouts spread out",
  "harbour-light": "Morning light over the harbour, seen from the studio window",
  "type-specimen": "A type specimen set at signage size",
  "workshop-wall": "The studio wall covered in rough ideas",
  "sketchbook": "An open sketchbook with a sign design",
  "finch-mark": "The Marlow and Finch mark on a studio door",
};
const out = {};
for (const [name, alt] of Object.entries(PICS)) {
  const form = new FormData();
  form.set("file", new Blob([readFileSync(new URL(`../pics/${name}.png`, import.meta.url))], { type: "image/png" }), `${name}.png`);
  form.set("alt", alt);
  const res = await fetch(`${EDITOR}/editor/media`, { method: "POST", headers: { cookie, Origin: EDITOR }, body: form });
  const json = await res.json().catch(() => ({}));
  console.log(name, res.status, JSON.stringify(json).slice(0, 160));
  out[name] = { key: json.key ?? json.picture?.key, alt };
}
writeFileSync(new URL("./pictures.json", import.meta.url), JSON.stringify(out, null, 2));
