// HecksAppeal IDE — Canvas Background Animation
//
// @domain Diagram
//
// Renders a domain graph: nodes represent aggregates, edges represent
// references. Nodes drift gently. When events fire, nodes pulse.
// Uses the actual domain structure pushed from the server.
//
// Respects prefers-reduced-motion — animation is disabled entirely.
//

(function () {
  "use strict";

  var canvas = document.getElementById("bg-canvas");
  if (!canvas) return;

  // Respect reduced motion
  var mq = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (mq.matches) return;

  var ctx = canvas.getContext("2d");
  var nodes = [];
  var edges = [];
  var animId = null;
  var time = 0;

  // ── Node / Edge Setup ───────────────────────────────────────

  function setDomainGraph(graph) {
    nodes = (graph.nodes || []).map(function (name, i) {
      var angle = (i / (graph.nodes.length || 1)) * Math.PI * 2;
      var cx = canvas.width / 2;
      var cy = canvas.height / 2;
      var radius = Math.min(cx, cy) * 0.6;
      return {
        name: name,
        x: cx + Math.cos(angle) * radius,
        y: cy + Math.sin(angle) * radius,
        vx: (Math.random() - 0.5) * 0.15,
        vy: (Math.random() - 0.5) * 0.15,
        pulse: 0,
        baseRadius: 3 + Math.random() * 2
      };
    });

    edges = (graph.edges || []).map(function (e) {
      return { from: e[0], to: e[1] };
    });
  }

  // Default graph until server pushes real data
  setDomainGraph({
    nodes: ["Project", "Session", "Document", "Explorer", "Generator", "Console", "Agent"],
    edges: [[0, 1], [0, 2], [0, 3], [0, 4], [0, 5], [0, 6], [2, 3]]
  });

  // ── Resize ──────────────────────────────────────────────────

  function resize() {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
  }

  window.addEventListener("resize", resize);
  resize();

  // ── Animation Loop ──────────────────────────────────────────

  function draw() {
    animId = requestAnimationFrame(draw);
    time += 0.005;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // Update node positions (gentle drift + sine wobble)
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      n.x += n.vx + Math.sin(time + i * 1.7) * 0.08;
      n.y += n.vy + Math.cos(time + i * 2.3) * 0.08;

      // Soft boundary bounce
      if (n.x < 40 || n.x > canvas.width - 40) n.vx *= -1;
      if (n.y < 40 || n.y > canvas.height - 40) n.vy *= -1;

      // Decay pulse
      if (n.pulse > 0) n.pulse *= 0.96;
    }

    // Draw edges
    ctx.strokeStyle = "rgba(67, 97, 238, 0.08)";
    ctx.lineWidth = 1;
    for (var j = 0; j < edges.length; j++) {
      var fromNode = nodes[edges[j].from];
      var toNode = nodes[edges[j].to];
      if (!fromNode || !toNode) continue;

      ctx.beginPath();
      ctx.moveTo(fromNode.x, fromNode.y);
      ctx.lineTo(toNode.x, toNode.y);
      ctx.stroke();
    }

    // Draw nodes
    for (var k = 0; k < nodes.length; k++) {
      var node = nodes[k];
      var r = node.baseRadius + node.pulse * 8;
      var alpha = 0.25 + node.pulse * 0.5;

      // Glow when pulsing
      if (node.pulse > 0.05) {
        ctx.beginPath();
        ctx.arc(node.x, node.y, r + 6, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(67, 97, 238, " + (node.pulse * 0.2) + ")";
        ctx.fill();
      }

      // Node dot
      ctx.beginPath();
      ctx.arc(node.x, node.y, r, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(67, 97, 238, " + alpha + ")";
      ctx.fill();
    }
  }

  draw();

  // ── Pulse a node (called when an event fires) ──────────────

  function pulseNode(aggregateName) {
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].name === aggregateName) {
        nodes[i].pulse = 1;
        break;
      }
    }
  }

  // ── Public API ──────────────────────────────────────────────

  window.HecksAnimation = {
    setGraph: setDomainGraph,
    pulse: pulseNode
  };

  // Listen for mq changes
  mq.addEventListener("change", function () {
    if (mq.matches) {
      cancelAnimationFrame(animId);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
    } else {
      draw();
    }
  });
})();
