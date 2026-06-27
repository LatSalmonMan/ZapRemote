# ZapRemote Roadmap

**North star (2031–2032):** Paper **$1B** company — the live sports second screen that syncs to your TV, skips the boring parts, and lands you on the best moments automatically.

**What we sell:** $5/mo premium automation for live sports on TV. Not a generic remote. Not a sports scores app. **Game night on autopilot.**

**Last updated:** June 2026 · **Current tag:** `working-v1`

---

## How to use this doc

1. **Pick one phase** — only work on the current phase until its exit criteria are met.
2. **Ship reliability before features** — a magic moment that works 9/10 times beats ten half-working ideas.
3. **Update checkboxes** when milestones land (commit with message like `roadmap: Phase 0 complete`).
4. **Ignore everything in “Not now”** until the phase says otherwise.

---

## Product pillars (never lose these)

| Pillar | User promise | Technical core |
|--------|--------------|----------------|
| **Sync** | App clock matches my TV scoreboard | Scoreboard seed + local tick + Hue delay offset (`GameClockSync`, `ESPNScoreboardClockService`) |
| **Skip** | Commercials → best highlight → back to live | `SportHighlightEngine`, `TVController` macros, multi-highlight loop |
| **Hands-free** | I don’t touch the phone during breaks | ESPN stoppage + cloud `ad_start` → `AdEventService` |
| **Trust** | It works on game night, every time | LG reconnect, Go Live, rewind sticker, error toasts |

**Out of scope until Phase 3+:** fantasy, betting, social, sports bars, Android, non-TV platforms.

---

## Financial milestones (paper valuation path)

Valuation is **equity on paper**, not cash in the bank. Target multiples assume strong retention + growth.

| Phase | Timeline | Paying subs (target) | ARR (at $5/mo) | Paper valuation range* |
|-------|----------|----------------------|-----------------|------------------------|
| **0 — Proof** | Now → Q4 2026 | 50 → 500 | $3K → $30K | Pre-seed / friends & family |
| **1 — Wedge** | 2027 | 5K → 25K | $600K → $3M | $5M → $20M |
| **2 — Scale** | 2028 | 100K → 250K | $12M → $30M | $80M → $200M |
| **3 — Category** | 2029 | 400K → 600K | $48M → $72M | $300M → $600M |
| **4 — Paper $1B** | 2030–2032 | 700K → 1M+ | $84M → $120M+ | **$800M → $1B+** (10–12× ARR or strategic exit) |

\*Illustrative. Actual multiple depends on growth rate, churn, margins, and strategic interest.

**Metrics that matter every month:**

- Paying subscribers
- **Game-night retention** — % who use app on 3+ live game nights in 30 days
- Skip success rate — ad trigger → highlight → Go Live without manual fix
- Clock sync confidence — user completes calibration and doesn’t resync mid-game
- MRR churn (especially off-season)

---

## Current state (baseline)

### Shipped / in progress

- [x] LG webOS control (`TVController`) — connect, macros, Go Live, multi-skip forward
- [x] ESPN game search — soccer-first leagues + US sports (`ESPNGameSearch`)
- [x] ESPN summary polling — plays, breaks, highlight ranking (`SportsAPIService`)
- [x] Multi-highlight commercial loop (up to 3 plays)
- [x] Hue-style timeline sync — slider + `user_stream_delay` persistence
- [x] Scoreboard one-shot clock seed + local wall-clock tick (`ESPNScoreboardClockService`)
- [x] ±1s fine-tune + resync from scoreboard (`SettingsView`)
- [x] Cloud ad detector bridge (`AdEventService` + `detector/`)
- [x] Premium UI shell — $5/mo checkout placeholder
- [x] Rewind flow sticker on home (`RemoteView`)

### Not reliable enough yet (Phase 0 focus)

- [ ] End-to-end ad skip works **3 games in a row** without manual intervention
- [ ] Clock stays aligned for full half (soccer + NFL)
- [ ] Go Live always returns to true live after highlight
- [ ] Real Stripe / App Store subscriptions (not placeholder)
- [ ] 10 external beta users with written feedback

---

## Phase 0 — **“It actually works”** (Q3–Q4 2026)

**Goal:** 50–500 paying or waitlisted users who’d be angry if you turned it off.

**Money:** Pre-revenue or first $500 MRR. Credibility > valuation.

### Engineering

- [ ] **Reliability sprint** — fix top 5 failure modes from real game nights (log in GitHub issues)
- [ ] **Soccer + NFL golden paths** — one test script per sport (pick game → sync → skip → live)
- [ ] **Onboarding flow** — first launch: connect TV → pick game → sync clock → test skip (5 screens max)
- [ ] **Error surfaces** — user always knows *why* skip failed and *what to do*
- [ ] **Subscription** — App Store IAP or Stripe live for $5/mo
- [ ] **Analytics** — track skip_attempt, skip_success, clock_resync, session_length (privacy-respecting)
- [ ] **README + ROADMAP** stay current after each release tag

### Distribution

- [ ] 15-second screen recording: ad → auto highlight → Go Live
- [ ] 10 beta users (friends, Reddit, soccer/NFL Twitter)
- [ ] Landing page — one sentence + waitlist + demo video
- [ ] Post in r/cordcutters, r/soccer, r/nfl when v1 is stable

### Exit criteria → Phase 1

- [ ] 3 consecutive live games per sport without manual clock fix mid-game
- [ ] ≥70% skip success in beta cohort
- [ ] 50+ active users OR 500 waitlist with 20% survey “would pay $5”

---

## Phase 1 — **“Can’t watch without it”** (2027)

**Goal:** 5K–25K subs · $600K–$3M ARR · seed round optional ($2–5M at $15–25M pre)

### Product

- [ ] **Hulu Live + Peacock** macro maps (10s skip services in `StreamingServicePreference`)
- [ ] **Halftime / period break** auto-detect tuned per league
- [ ] **Push notification** — “Commercial — skipping to highlight” (optional)
- [ ] **Skip history** — last 3 rewinds with play description (trust + debug)
- [ ] **Offline / API failure** — graceful generic skip when ESPN down
- [ ] **iPad layout** — same phone flow, bigger clock UI

### Engineering

- [ ] Unit tests on `GameClockSyncEngine`, `SportHighlightEngine`
- [ ] Integration test harness — mock ESPN JSON fixtures
- [ ] Crash-free sessions > 99.5%

### Distribution

- [ ] Seasonal campaigns — NFL playoffs, Champions League, World Cup qualifiers
- [ ] Influencer seeding — 5 sports creators with LG + YouTube TV
- [ ] Referral — give a month free for each paying referral

### Exit criteria → Phase 2

- [ ] 5K paying subs
- [ ] <8% monthly churn during active season
- [ ] 40%+ “3+ game nights per month” retention

---

## Phase 2 — **“Multi-platform wedge”** (2028)

**Goal:** 100K–250K subs · $12–30M ARR · Series A ($15–30M at $80–150M pre)

### Product

- [ ] **Samsung Tizen** TV control (largest US TV share)
- [ ] **Roku** — if API/partner path exists; else phone-as-bridge
- [ ] **Apple TV / Fire TV** — at least one additional stream device
- [ ] **Android app** — feature parity with iOS core loop
- [ ] **Account sync** — game + clock settings across devices (iCloud or backend)
- [ ] **Family plan** — $15/mo for 3 TVs

### Moat building

- [ ] **Proprietary sync** — document + patent provisional on timeline calibration method
- [ ] **Highlight quality scoring** — learn from which plays users re-watch
- [ ] **League-specific break models** — NFL vs soccer vs NBA timeout patterns

### Business

- [ ] Hire 1–2 engineers, 1 growth/partnerships
- [ ] Legal review — ToS, streaming macro risk memo
- [ ] Partnership talks — YouTube TV affiliate? Sports podcast bundles?

### Exit criteria → Phase 3

- [ ] 100K paying subs
- [ ] Works on ≥2 TV brands + ≥2 streaming apps for 80% of users
- [ ] $12M+ ARR run rate

---

## Phase 3 — **“Second screen platform”** (2029)

**Goal:** 400K–600K subs · $48–72M ARR · Series B or profitable growth

### Product (only after Phase 2 retention is solid)

- [ ] **Live play alerts** — synced to *your* TV delay, tap to rewind on TV
- [ ] **“Rewind that play”** from notification → one-tap macro
- [ ] **Watch party sync** — friends’ clocks aligned (SharePlay or custom)
- [ ] **Fantasy / betting hooks** — API partners (DraftKings, Sleeper) — **link only, no gambling in app**
- [ ] **Sports bar mode** — one iPad controls multiple TVs (B2B pilot)
- [ ] **API for partners** — “ZapRemote Sync” licensing

### Brand

- [ ] Rename consideration — does “ZapRemote” scale to platform? (decide by 2028)
- [ ] Game-night identity — logo on par with DraftKings-level polish at key moments

### Exit criteria → Phase 4

- [ ] 400K+ subs OR $40M+ ARR
- [ ] Known in sports Twitter / podcast circuit
- [ ] Inbound acquisition interest from streamer, OEM, or sports media

---

## Phase 4 — **“Paper billion”** (2030–2032)

**Goal:** $80–120M+ ARR **or** strategic acquisition at $800M–$1B+

### Paths (pick one primary, keep the other as backup)

**Path A — Subscription scale**

- 700K–1M paying users at $10–12/mo
- Expand internationally — Premier League, La Liga, Liga MX core users
- Enterprise / venue licensing adds $5–10M ARR

**Path B — Strategic exit**

- Acquirers: Roku, Amazon, Google, Disney/ESPN, DraftKings, FanDuel, Apple
- Pitch: engaged live sports audience + sync IP + hands-free TV control they can’t build fast

### What “paper $1B” means for you personally

- You likely own 40–70% early; dilution through rounds brings it down
- **Paper $1B company ≠ $1B in your bank account**
- Liquidity: IPO, acquisition, or secondary sale of shares

---

## Codebase map (where work lives)

| Area | Files | Roadmap relevance |
|------|-------|-------------------|
| TV control | `TVController.swift` | Skip macros, Go Live, device support expansion |
| ESPN + clock | `SportsAPIService.swift`, `GameClockSync.swift`, `ESPNScoreboardClockService.swift` | Sync moat — protect and perfect |
| Highlights | `SportHighlight.swift`, `HighlightRewindPlanning.swift` | Skip quality |
| Ad detection | `AdEventService.swift`, `detector/` | Hands-free accuracy |
| UI | `RemoteView.swift`, `SettingsView.swift`, `TimelineSyncView.swift` | Onboarding, trust, calibration |
| Game pick | `ESPNGameSearch.swift`, `GameSearchSheet.swift` | League coverage |
| Monetization | `PremiumCheckoutView.swift` | Phase 0 — real payments |
| Theme | `AppThemeEngine.swift` | Brand consistency |

---

## Not now (focus guardrails)

Do **not** build these until Phase 3 unless a paying user cohort explicitly demands it:

- AI chat / generic assistant features
- Non-sports TV (news, reality shows)
- Building your own streaming service
- Crypto / NFT / tokens
- Desktop Mac/Windows remote (unless detector expansion requires it)
- Custom hardware remote
- Full fantasy league management inside the app

---

## Release tagging convention

| Tag | Meaning |
|-----|---------|
| `working-v1` | Core loop compiles and works in happy path |
| `beta-v1` | Phase 0 exit criteria met — external users |
| `v1.0` | App Store launch — paid subs live |
| `v1.x` | Phase 1 increments |
| `v2.0` | Multi-platform (Phase 2) |

---

## Weekly focus template (copy into issues or Notes)

```text
Week of: ___________
Phase: ___
One metric I'm moving: ___________

This week ONLY:
1.
2.
3.

Not this week:
-

Ship by Friday:
-
```

---

## Decision log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-06 | $5/mo flat premium | Dad test + cord-cutter feedback — $10 felt too high |
| 2026-06 | Soccer-first game search | Core user base watches football/soccer |
| 2026-06 | Scoreboard seed + local tick | API latency; user spec; fewer clock jumps |
| 2026-06 | LG + YouTube TV first | Founder dogfood stack; prove wedge |
| 2026-06 | Paper $1B by ~2032 | North star; requires platform evolution |

_Add rows when you make strategic calls — future you will thank present you._

---

## Immediate next actions (as of June 2026)

1. Run **two full live games** (one soccer, one NFL) — log every failure
2. Fix failures until **three clean games in a row**
3. Record **demo video**
4. Get **10 beta users**
5. Wire **real payments**
6. Tag `beta-v1` when Phase 0 exit criteria hit

**The dream is 2032. The work is this week.**
