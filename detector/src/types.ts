export type AdCloudEventType = "ad_start" | "game_live";

export interface AdCloudEvent {
  event: AdCloudEventType;
  game_id?: string;
  channel?: string;
  broadcast_ts?: number;
  suggested_rewind_seconds?: number;
  confidence?: number;
  signals?: string[];
}

export interface DetectorConfig {
  port: number;
  gameId: string;
  espnSportPath: string;
  channel: string;
  hlsUrl: string | null;
  espnPollMs: number;
  hlsPollMs: number;
  suggestedRewindSeconds: number;
  enableEspnStoppageFallback: boolean;
}

export interface ClientConfigMessage {
  event: "client_config";
  game_id: string;
  sport_path: string;
}
