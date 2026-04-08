// HecksAppeal IDE — Screenshot Streaming
//
// Captures the browser DOM as a low-quality JPEG every second
// and sends it to the server for visual debugging. The server
// maintains a rolling buffer of 100 images that Claude can read.
//
//   Requires window.HecksIDE.command() from socket.js
//   Requires html2canvas (loaded via CDN in layout.html)
//

(function () {
  "use strict";

  var capturing = true;
  var interval = null;
  var busy = false;
  var CAPTURE_MS = 1000;
  var QUALITY = 0.3;
  var MAX_WIDTH = 800;

  function startCapture() {
    if (interval) return;
    interval = setInterval(captureFrame, CAPTURE_MS);
  }

  function stopCapture() {
    if (interval) {
      clearInterval(interval);
      interval = null;
    }
  }

  function captureFrame() {
    if (!capturing || busy) return;
    if (typeof html2canvas === "undefined") {
      console.warn("[screenshots] html2canvas not loaded");
      return;
    }

    var target = document.getElementById("ide");
    if (!target) return;

    busy = true;
    html2canvas(target, {
      scale: Math.min(1, MAX_WIDTH / target.offsetWidth),
      logging: false,
      useCORS: true,
      backgroundColor: "#0d0d0d"
    }).then(function (canvas) {
      var dataUrl = canvas.toDataURL("image/jpeg", QUALITY);
      var base64 = dataUrl.split(",")[1];

      if (base64 && window.HecksIDE) {
        window.HecksIDE.command("Screenshot", "CaptureScreen", {
          frame_data: base64,
          timestamp: new Date().toISOString()
        });
      }
      busy = false;
    }).catch(function (err) {
      console.warn("[screenshots] capture failed:", err);
      busy = false;
    });
  }

  function init() {
    startCapture();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    setTimeout(init, 1000);
  }

  window.HecksScreenshots = {
    pause: function () { capturing = false; stopCapture(); },
    resume: function () { capturing = true; startCapture(); }
  };
})();
