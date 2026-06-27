import { EspnMonitor } from "./espn-monitor.js";
import { Scte35Monitor } from "./scte35-monitor.js";
import type { DetectorConfig } from "./types.js";
import { WebSocketHub } from "./websocket-hub.js";

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function loadConfig(): DetectorConfig {
  const gameId = process.env.ESPN_GAME_ID?.trim() || "";
  const espnSportPath = process.env.ESPN_SPORT_PATH?.trim() || "";
  const hlsUrl = process.env.HLS_URL?.trim() || null;

  return {
    port: envInt("PORT", 8787),
    gameId,
    espnSportPath,
    channel: process.env.CHANNEL?.trim() || "ESPN",
    hlsUrl,
    espnPollMs: envInt("ESPN_POLL_MS", 3000),
    hlsPollMs: envInt("HLS_POLL_MS", 2000),
    suggestedRewindSeconds: envInt("SUGGESTED_REWIND_SECONDS", 120),
    enableEspnStoppageFallback: process.env.ESPN_STOPPAGE_FALLBACK !== "0",
  };
}

function main(): void {
  const config = loadConfig();
  const hub = new WebSocketHub(config.port);

  const broadcast = hub.broadcast.bind(hub);

  if (config.hlsUrl) {
    const scte = new Scte35Monitor(
      config.hlsUrl,
      config.hlsPollMs,
      broadcast,
      config.gameId,
      config.channel,
      config.suggestedRewindSeconds
    );
    scte.start();
    console.log("✅ Primary ad detection: SCTE-35 / HLS cue tags");
  } else {
    console.log("ℹ️  No HLS_URL — SCTE-35 detection disabled");
    if (!config.enableEspnStoppageFallback) {
      console.log("⚠️  ESPN stoppage fallback also disabled — only game_live events will fire");
    }
  }

  const espn = new EspnMonitor(
    config.gameId,
    config.espnSportPath,
    config.channel,
    config.espnPollMs,
    (event) => {
      // When SCTE-35 is active, only use ESPN for game_live (not fallback ad_start).
      if (config.hlsUrl && event.event === "ad_start") return;
      broadcast(event);
    },
    config.enableEspnStoppageFallback && !config.hlsUrl,
    config.suggestedRewindSeconds
  );

  hub.setClientConfigHandler((clientConfig) => {
    espn.configure(clientConfig.game_id, clientConfig.sport_path);
  });

  espn.start();

  console.log("");
  console.log("ZapRemote Ad Detector");
  console.log(`  WebSocket   ws://0.0.0.0:${config.port}`);
  console.log(
    `  Game ID     ${config.gameId || "(waiting — connect iPhone or set ESPN_GAME_ID)"}`
  );
  console.log(
    `  Sport path  ${config.espnSportPath || "(waiting — connect iPhone or set ESPN_SPORT_PATH, e.g. football/nfl)"}`
  );
  console.log(`  HLS feed    ${config.hlsUrl ?? "(none — set HLS_URL for real ad cues)"}`);
  console.log(`  ESPN fallback ads: ${config.hlsUrl ? "off (SCTE-35 primary)" : config.enableEspnStoppageFallback}`);
  console.log("");
  console.log("Point the iPhone app at ws://<this-mac-ip>:8787 (Settings → Ad Detection)");
}

main();
