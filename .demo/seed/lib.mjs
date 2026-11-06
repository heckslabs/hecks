// Tiny helpers for building the domain's structured body from light markup.
export const v = (value) => ({ value });

/** "plain **bold** *italic* [label](url) line\\nbreak" -> spans */
export function spans(text) {
  const out = [];
  const re = /\*\*(.+?)\*\*|\*(.+?)\*|\[(.+?)\]\((.+?)\)/g;
  let last = 0, m;
  const plain = (t) => t && out.push({ text: t, marks: [] });
  while ((m = re.exec(text))) {
    plain(text.slice(last, m.index));
    if (m[1]) out.push({ text: m[1], marks: [{ name: "bold" }] });
    else if (m[2]) out.push({ text: m[2], marks: [{ name: "italic" }] });
    else out.push({ text: m[3], marks: [], href: m[4] });
    last = re.lastIndex;
  }
  plain(text.slice(last));
  return out.length ? out : [{ text: "", marks: [] }];
}
export const P = (t) => ({ kind: "paragraph", spans: spans(t), items: [] });
export const H = (t, level = 2) => ({ kind: "heading", level, spans: spans(t), items: [] });
export const Q = (t) => ({ kind: "quote", spans: spans(t), items: [] });
export const HR = () => ({ kind: "divider", spans: [], items: [] });
/** items: strings, or [string, depth] */
export const UL = (...items) => list("bullet_list", items);
export const OL = (...items) => list("numbered_list", items);
function list(kind, items) {
  return { kind, spans: [], items: items.map((i) => {
    const [t, d = 0] = Array.isArray(i) ? i : [i];
    return { spans: spans(t), depth: d, list_kind: kind };
  }) };
}
export const IMG = (key, alt, caption) => ({ kind: "image", spans: [], items: [], media_ref: key, alt, ...(caption ? { caption } : {}) });
export const body = (...blocks) => ({ blocks });
