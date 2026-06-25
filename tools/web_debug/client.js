// [antibody-exempt: tools/web_debug/client.js — browser-side canvas capture
//  glue. Runs in the BROWSER (grabs the canvas as a JPEG, POSTs
//  Screenshot.Capture to a storehouse serve /dispatch endpoint) ; cannot be
//  bluebook vocabulary. Permanent — Chris chose the registry/permanent path,
//  2026-06-25.]
// web_debug/client.js — canvas screenshot streaming, STANDALONE.
//
// The Rust port of the Ruby :web_debug CLIENT_JS, with the HecksIDE / HecksApp
// coupling removed : it works on ANY page with a <canvas>. Every interval it
// grabs the canvas as a JPEG and POSTs Screenshot.Capture to a storehouse serve
// /dispatch endpoint ; the out-of-process DiskBuffer handler writes
// /tmp/ha_screenshots/latest.jpg, so an agent reads the latest frame instead of
// driving a browser by hand.
//
// Include after your canvas, and (optionally) configure :
//   window.HECKS_DEBUG = { api: 'http://localhost:8799', canvas: '#c', interval: 1000 };
//   <script src="/tools/web_debug/client.js"></script>
(function () {
  "use strict";
  var cfg = window.HECKS_DEBUG || {};
  var API = cfg.api || "";                 // same-origin by default
  var interval = cfg.interval || 1000;     // ms between frames
  var sel = cfg.canvas || "canvas";        // selector or element
  var quality = cfg.quality || 0.6;
  var n = 0, dot = null;

  function makeDot() {
    dot = document.createElement("div");
    dot.style.cssText = "position:fixed;bottom:8px;right:8px;width:8px;height:8px;" +
      "border-radius:50%;background:#22c55e;opacity:0;transition:opacity .3s;" +
      "pointer-events:none;z-index:99999";
    document.body.appendChild(dot);
  }
  function flash() { if (dot) { dot.style.opacity = "1"; setTimeout(function () { dot.style.opacity = "0"; }, 350); } }

  function frame() {
    var cv = (typeof sel === "string") ? document.querySelector(sel) : sel;
    if (!cv || !cv.toDataURL) return;
    var data;
    try { data = cv.toDataURL("image/jpeg", quality); } catch (e) { return; }
    n++;
    fetch(API + "/dispatch", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        command: "WebDebug::Screenshot.Capture",
        attrs: { frame_id: String(n), captured_at: new Date().toISOString(), frame_data: data }
      })
    }).then(flash).catch(function () {});
  }

  function start() { makeDot(); setInterval(frame, interval); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { setTimeout(start, 1000); });
  else setTimeout(start, 1000);

  window.HecksDebug = { frame: frame };
})();
