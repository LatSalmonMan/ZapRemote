# ZapRemote

iOS TV remote for LG webOS TVs — commercial-break automation with ESPN highlight targeting and optional broadcast ad detection.

> **Status: WIP** — Core loop shipped (`working-v1`). See **[ROADMAP.md](ROADMAP.md)** for product + valuation milestones and what to build next.

## iOS app

Open `ZapRemote/ZapRemote.xcodeproj` in Xcode, select your iPhone, and run.

## Ad detector (cloud brain)

The phone cannot see ads on your TV. Run the detector on a Mac on the same Wi‑Fi:

```bash
cd detector
npm install
cp .env.example .env
npm start
```

Then in the app: **Settings → Ad Detection** → `ws://<your-mac-ip>:8787` → **Connect**.

See [detector/README.md](detector/README.md) for `HLS_URL` / SCTE-35 setup (real broadcast ad cues).

## Flow

1. Connect LG TV (auto-reconnects if previously paired)
2. **Choose Game** — pick the live ESPN game you're watching
3. **Match Clock** — use −/+ until the ticking clock matches your TV
4. On commercials: tap **Ad on my TV**, or enable hands-free for halftime/TV timeouts
5. Optional: Mac ad detector on `ws://<mac-ip>:8787` for broadcast ad cues
