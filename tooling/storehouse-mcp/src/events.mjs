// events.mjs
//
// AgentEventStreamResource — exposes the i17 emit_to_agent JSONL feed
// (default /tmp/miette_agent_events.jsonl, overridable via the env var
// HECKS_AGENT_EVENT_STREAM) as the MCP resource `storehouse://events`.
//
// Wiring :
//   - resources/list   → returns one entry, the events resource
//   - resources/read   → returns the full file contents (text/plain)
//   - resources/subscribe → starts a fs.watch on the file and sends
//     `notifications/resources/updated` each time it grows
//
// The MCP SDK doesn't ship a high-level "send a string per new line"
// notification, but the standard "resource updated" pattern lets the
// client re-read on each ping — equivalent semantic for a live tail.

import { existsSync, readFileSync, statSync, watch, openSync, readSync, closeSync } from "node:fs";
import { dirname } from "node:path";
import {
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
  SubscribeRequestSchema,
  UnsubscribeRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

export const EVENTS_URI = "storehouse://events";

function streamPath() {
  return process.env.HECKS_AGENT_EVENT_STREAM || "/tmp/miette_agent_events.jsonl";
}

// Read trailing bytes from the file starting at lastOffset. Returns
// { content, newOffset } so the caller can advance its watermark.
function readSince(path, lastOffset) {
  if (!existsSync(path)) return { content: "", newOffset: 0 };
  const stats = statSync(path);
  // file truncated / rotated → reset to head
  if (stats.size < lastOffset) lastOffset = 0;
  if (stats.size === lastOffset) return { content: "", newOffset: lastOffset };
  const fd = openSync(path, "r");
  try {
    const length = stats.size - lastOffset;
    const buf = Buffer.alloc(length);
    readSync(fd, buf, 0, length, lastOffset);
    return { content: buf.toString("utf8"), newOffset: stats.size };
  } finally {
    closeSync(fd);
  }
}

export function registerEventsResource(server) {
  const lowLevel = server.server;
  const state = {
    lastOffset: existsSync(streamPath()) ? statSync(streamPath()).size : 0,
    watcher: null,
    subscribed: false,
  };

  lowLevel.setRequestHandler(ListResourcesRequestSchema, async () => ({
    resources: [
      {
        uri: EVENTS_URI,
        name: "Storehouse agent events",
        description:
          "Live JSONL feed of emit_to_agent events from the storehouse runtime (i17). Each line is one event ; subscribe to receive notifications/resources/updated on new lines.",
        mimeType: "application/x-ndjson",
      },
    ],
  }));

  lowLevel.setRequestHandler(ReadResourceRequestSchema, async (request) => {
    if (request.params.uri !== EVENTS_URI) {
      throw new Error(`unknown resource: ${request.params.uri}`);
    }
    const path = streamPath();
    const text = existsSync(path) ? readFileSync(path, "utf8") : "";
    return {
      contents: [
        {
          uri: EVENTS_URI,
          mimeType: "application/x-ndjson",
          text,
        },
      ],
    };
  });

  const startWatcher = () => {
    if (state.watcher) return;
    const path = streamPath();
    const watchTarget = existsSync(path) ? path : dirname(path);
    try {
      state.watcher = watch(watchTarget, { persistent: false }, () => {
        if (!existsSync(path)) return;
        const { content, newOffset } = readSince(path, state.lastOffset);
        if (content && state.subscribed) {
          state.lastOffset = newOffset;
          lowLevel
            .notification({
              method: "notifications/resources/updated",
              params: { uri: EVENTS_URI },
            })
            .catch((err) => {
              process.stderr.write(
                `[storehouse-mcp] events notify failed: ${err.message}\n`,
              );
            });
        } else if (content) {
          state.lastOffset = newOffset;
        }
      });
    } catch (err) {
      process.stderr.write(
        `[storehouse-mcp] events watcher failed: ${err.message}\n`,
      );
    }
  };

  lowLevel.setRequestHandler(SubscribeRequestSchema, async (request) => {
    if (request.params.uri !== EVENTS_URI) {
      throw new Error(`unknown resource: ${request.params.uri}`);
    }
    state.subscribed = true;
    startWatcher();
    return {};
  });

  lowLevel.setRequestHandler(UnsubscribeRequestSchema, async (request) => {
    if (request.params.uri !== EVENTS_URI) return {};
    state.subscribed = false;
    if (state.watcher) {
      state.watcher.close();
      state.watcher = null;
    }
    return {};
  });

  return state;
}
