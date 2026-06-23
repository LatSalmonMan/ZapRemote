import type { AdCloudEvent } from "./types.js";

type AdSignalHandler = (event: AdCloudEvent) => void;

/**
 * Polls an HLS media playlist for SCTE-35 / cue tags that mark ad breaks.
 * Fires ad_start on CUE-OUT / SCTE35-OUT and game_live on CUE-IN.
 */
export class Scte35Monitor {
  private inAdBreak = false;
  private lastFingerprint = "";
  private lastAdStartAt = 0;
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly hlsUrl: string,
    private readonly pollMs: number,
    private readonly onSignal: AdSignalHandler,
    private readonly gameId: string,
    private readonly channel: string,
    private readonly suggestedRewindSeconds: number
  ) {}

  start(): void {
    console.log(`📺 SCTE-35 monitor → ${this.hlsUrl}`);
    void this.poll();
    this.timer = setInterval(() => void this.poll(), this.pollMs);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private async poll(): Promise<void> {
    try {
      const response = await fetch(this.hlsUrl, {
        headers: { "User-Agent": "ZapRemote-AdDetector/1.0" },
      });
      if (!response.ok) {
        console.warn(`⚠️ HLS fetch HTTP ${response.status}`);
        return;
      }

      const playlist = await response.text();
      const fingerprint = this.fingerprint(playlist);
      if (fingerprint === this.lastFingerprint) return;
      this.lastFingerprint = fingerprint;

      const cueOut = this.hasCueOut(playlist);
      const cueIn = this.hasCueIn(playlist);

      if (cueOut && !this.inAdBreak) {
        const now = Date.now();
        if (now - this.lastAdStartAt < 45_000) return;

        this.inAdBreak = true;
        this.lastAdStartAt = now;
        this.onSignal({
          event: "ad_start",
          game_id: this.gameId,
          channel: this.channel,
          broadcast_ts: Date.now() / 1000,
          suggested_rewind_seconds: this.suggestedRewindSeconds,
          confidence: 0.94,
          signals: this.extractSignals(playlist),
        });
      }

      if (cueIn && this.inAdBreak) {
        this.inAdBreak = false;
        this.onSignal({
          event: "game_live",
          game_id: this.gameId,
          channel: this.channel,
          broadcast_ts: Date.now() / 1000,
          confidence: 0.94,
          signals: ["scte35_cue_in"],
        });
      }
    } catch (error) {
      console.warn(`⚠️ HLS poll error: ${(error as Error).message}`);
    }
  }

  private fingerprint(playlist: string): string {
    const cues = playlist
      .split("\n")
      .filter((line) => /CUE-OUT|CUE-IN|SCTE35|DATERANGE|SPLICE/i.test(line))
      .join("|");
    return cues || playlist.slice(-120);
  }

  private hasCueOut(playlist: string): boolean {
    return /#EXT-X-CUE-OUT|#EXT-X-SPLICE-OUT|SCTE35-OUT/i.test(playlist);
  }

  private hasCueIn(playlist: string): boolean {
    return /#EXT-X-CUE-IN|#EXT-X-SPLICE-IN|SCTE35-IN/i.test(playlist);
  }

  private extractSignals(playlist: string): string[] {
    const signals: string[] = [];
    if (/#EXT-X-CUE-OUT/i.test(playlist)) signals.push("scte35_cue_out");
    if (/SCTE35-OUT/i.test(playlist)) signals.push("scte35_daterange");
    if (/#EXT-X-SPLICE-OUT/i.test(playlist)) signals.push("splice_out");
    return signals.length ? signals : ["scte35"];
  }
}
