import http from "node:http";
const UP = 48420;
http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/frame") {
    const w = u.searchParams.get("w") || "375", h = u.searchParams.get("h") || "760", src = u.searchParams.get("src") || "/editor";
    res.setHeader("content-type", "text/html");
    return res.end(`<!doctype html><body style="margin:0;background:#888"><iframe id=f src="${src}" style="width:${w}px;height:${h}px;border:0;background:#fff;display:block;margin:0 auto"></iframe></body>`);
  }
  const up = http.request({ host: "127.0.0.1", port: UP, path: req.url, method: req.method, headers: { ...req.headers } }, (r) => {
    const h = { ...r.headers };
    if (h["content-security-policy"]) h["content-security-policy"] = h["content-security-policy"].replace("frame-ancestors 'none'", "frame-ancestors 'self'");
    res.writeHead(r.statusCode, h); r.pipe(res);
  });
  req.pipe(up);
}).listen(48440, "127.0.0.1");
