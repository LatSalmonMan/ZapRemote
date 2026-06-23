import type { AdCloudEvent } from "./types.js";

type EspnSignalHandler = (event: AdCloudEvent) => void;

interface EspnStatusType {
  name: string;
  state?: string;
  description?: string;
  detail?: string;
  shortDetail?: string;
}

interface EspnPlay {
  id?: string;
  text?: string;
  wallclock?: string;
  type?: { text?: string; abbreviation?: string };
}

interface EspnSummary {
  header?: { competitions?: Array<{ status?: { type: EspnStatusType; detail?: string; shortDetail?: string } }> };
  drives?: {
    previous?: Array<{ plays?: EspnPlay[] }>;
    current?: { plays?: EspnPlay[] };
  };
}

const BREAK_KEYWORDS = [
  "timeout",
  "halftime",
  "commercial",
  "two-minute warning",
  "end of period",
  "official timeout",
];

const BREAK_STATUS = new Set([
  "STATUS_HALFTIME",
  "STATUS_TIMEOUT",
  "STATUS_TV_TIMEOUT",
  "STATUS_END_PERIOD",
  "STATUS_END_OF_PERIOD",
  "STATUS_INTERMISSION",
]);

const ACTIVE_KEYWORDS = [
  "in progress",
  "rush",
  "pass",
  "kickoff",
  "punt",
  "field goal",
  "touchdown",
  "interception",
  "fumble",
  "sack",
];

/**
 * ESPN game feed — emits game_live when play resumes.
 * Optional fallback ad_start on game stoppage (lower confidence than SCTE-35).
 */
export class EspnMonitor {
  private timer: NodeJS.Timeout | null = null;
  private inBreak = false;
  private hasFiredBreak = false;

  constructor(
    private readonly gameId: string,
    private readonly channel: string,
    private readonly pollMs: number,
    private readonly onSignal: EspnSignalHandler,
    private readonly enableStoppageFallback: boolean,
    private readonly suggestedRewindSeconds: number
  ) {}

  start(): void {
    console.log(`🏈 ESPN monitor → game ${this.gameId}`);
    void this.poll();
    this.timer = setInterval(() => void this.poll(), this.pollMs);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private async poll(): Promise<void> {
    try {
      const url = `https://site.api.espn.com/apis/site/v2/sports/football/nfl/summary?event=${this.gameId}`;
      const response = await fetch(url);
      if (!response.ok) {
        console.warn(`⚠️ ESPN HTTP ${response.status}`);
        return;
      }

      const summary = (await response.json()) as EspnSummary;
      const status = summary.header?.competitions?.[0]?.status;
      const latestPlay = this.latestPlay(summary);
      const onBreak = this.isBreak(status, latestPlay);
      const onActivePlay = !onBreak && this.isActivePlay(status, latestPlay);

      if (onBreak) {
        this.inBreak = true;
        if (this.enableStoppageFallback && !this.hasFiredBreak) {
          this.hasFiredBreak = true;
          this.onSignal({
            event: "ad_start",
            game_id: this.gameId,
            channel: this.channel,
            broadcast_ts: Date.now() / 1000,
            suggested_rewind_seconds: this.suggestedRewindSeconds,
            confidence: 0.72,
            signals: ["espn_stoppage"],
          });
        }
        return;
      }

      if (onActivePlay && (this.inBreak || this.hasFiredBreak)) {
        this.inBreak = false;
        this.hasFiredBreak = false;
        this.onSignal({
          event: "game_live",
          game_id: this.gameId,
          channel: this.channel,
          broadcast_ts: Date.now() / 1000,
          confidence: 0.88,
          signals: ["espn_play_resumed"],
        });
      }
    } catch (error) {
      console.warn(`⚠️ ESPN poll error: ${(error as Error).message}`);
    }
  }

  private latestPlay(summary: EspnSummary): EspnPlay | undefined {
    const current = summary.drives?.current?.plays;
    if (current?.length) return current[current.length - 1];
    const previous = summary.drives?.previous;
    if (!previous?.length) return undefined;
    const lastDrive = previous[previous.length - 1];
    const plays = lastDrive.plays;
    return plays?.length ? plays[plays.length - 1] : undefined;
  }

  private haystack(parts: Array<string | undefined>): string {
    return parts.filter(Boolean).join(" ").toLowerCase();
  }

  private isBreak(
    status: { type: EspnStatusType; detail?: string; shortDetail?: string } | undefined,
    play: EspnPlay | undefined
  ): boolean {
    if (status) {
      const typeName = status.type.name.toUpperCase();
      if (BREAK_STATUS.has(typeName)) return true;
      const statusHaystack = this.haystack([
        status.type.description,
        status.type.detail,
        status.type.shortDetail,
        status.detail,
        status.shortDetail,
      ]);
      if (BREAK_KEYWORDS.some((k) => statusHaystack.includes(k))) return true;
    }

    const playHaystack = this.haystack([play?.text, play?.type?.text, play?.type?.abbreviation]);
    return BREAK_KEYWORDS.some((k) => playHaystack.includes(k));
  }

  private isActivePlay(
    status: { type: EspnStatusType } | undefined,
    play: EspnPlay | undefined
  ): boolean {
    if (status) {
      const typeName = status.type.name.toUpperCase();
      if (typeName === "STATUS_IN_PROGRESS") return true;
      if (status.type.state?.toLowerCase() === "in") return true;
    }
    const playHaystack = this.haystack([play?.text, play?.type?.text, play?.type?.abbreviation]);
    return ACTIVE_KEYWORDS.some((k) => playHaystack.includes(k)) || playHaystack.includes("in progress");
  }
}
