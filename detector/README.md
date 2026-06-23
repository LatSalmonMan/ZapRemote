# ZapRemote Ad Detector

Cloud brain for ZapRemote — watches the **broadcast feed** and pushes `ad_start` / `game_live` events to the iPhone over WebSocket.

## What it detects

| Signal | Source | Confidence | Meaning |
|--------|--------|------------|---------|
| `scte35_cue_out` | HLS playlist (`HLS_URL`) | ~0.94 | **Real ad break** (broadcast SCTE-35 cue) |
| `espn_stoppage` | ESPN API (fallback only) | ~0.72 | Game stopped — ads *may* be on TV |
| `espn_play_resumed` | ESPN API | ~0.88 | Game back — return to live |

When `HLS_URL` is set, **only SCTE-35** triggers `ad_start`. ESPN is used for `game_live`.

## Quick start

```bash
cd detector
npm install
cp .env.example .env
# Edit .env — set ESPN_GAME_ID and optionally HLS_URL
npm start
```

Server listens on **`ws://0.0.0.0:8787`**.

## Connect the iPhone app

1. Mac and iPhone on the **same Wi‑Fi**
2. Find your Mac's IP: System Settings → Network → Wi‑Fi → Details
3. In ZapRemote **Settings → Ad Detection**, set:
   ```
   ws://192.168.x.x:8787
   ```
4. Tap **Connect** — status should show **Cloud brain connected**
5. **Sync Stream Lag** on Home, then watch a live game

Simulator can use `ws://127.0.0.1:8787`.

## HLS_URL (real ads)

Point `HLS_URL` at an HLS media playlist that includes ad markers, for example:

- `#EXT-X-CUE-OUT`
- `#EXT-X-CUE-IN`
- `#EXT-X-DATERANGE` with `SCTE35-OUT`

Linear sports streams from cable/OTA restreams often include these. YouTube TV / Hulu streams on the phone are **not** accessible to this server — you need a feed of the **broadcast** (antenna, cable, or provider HLS).

## Event format

```json
{
  "event": "ad_start",
  "game_id": "401547417",
  "channel": "ESPN",
  "broadcast_ts": 1718543400.12,
  "suggested_rewind_seconds": 120,
  "confidence": 0.94,
  "signals": ["scte35_cue_out"]
}
```

```json
{
  "event": "game_live",
  "game_id": "401547417",
  "confidence": 0.88,
  "signals": ["espn_play_resumed"]
}
```

## Test without HLS

With no `HLS_URL`, the detector uses ESPN stoppage fallback (`ESPN_STOPPAGE_FALLBACK=1`). Good for dev — not true ad detection.

Use **Settings → Developer Tools → Simulate Cloud Ad Detected** to test the phone path without the server.
