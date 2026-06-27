import type { WebSocket } from "ws";
import { WebSocketServer } from "ws";
import type { AdCloudEvent, ClientConfigMessage } from "./types.js";

type ClientConfigHandler = (config: ClientConfigMessage) => void;

export class WebSocketHub {
  private readonly wss: WebSocketServer;
  private clients = new Set<WebSocket>();
  private onClientConfig: ClientConfigHandler | null = null;

  constructor(port: number) {
    this.wss = new WebSocketServer({ port });
    this.wss.on("connection", (socket) => {
      this.clients.add(socket);
      socket.on("message", (raw) => this.handleMessage(raw));
      socket.on("close", () => this.clients.delete(socket));
      socket.on("error", () => this.clients.delete(socket));
      socket.send(
        JSON.stringify({
          event: "detector_hello",
          message: "ZapRemote ad detector connected",
          clients: this.clients.size,
        })
      );
      console.log(`📱 client connected (${this.clients.size} total)`);
    });
    console.log(`🔌 WebSocket hub listening on ws://0.0.0.0:${port}`);
  }

  broadcast(event: AdCloudEvent): void {
    const payload = JSON.stringify(event);
    for (const client of this.clients) {
      if (client.readyState === client.OPEN) {
        client.send(payload);
      }
    }
    console.log(
      `📡 broadcast ${event.event} → ${this.clients.size} client(s) ` +
        `(confidence ${event.confidence ?? 1}, signals ${(event.signals ?? []).join(",")})`
    );
  }

  clientCount(): number {
    return this.clients.size;
  }

  setClientConfigHandler(handler: ClientConfigHandler): void {
    this.onClientConfig = handler;
  }

  private handleMessage(raw: WebSocket.RawData): void {
    if (!this.onClientConfig) return;

    try {
      const text = typeof raw === "string" ? raw : raw.toString("utf8");
      const parsed = JSON.parse(text) as Partial<ClientConfigMessage>;
      if (parsed.event !== "client_config") return;

      const gameId = parsed.game_id?.trim();
      const sportPath = parsed.sport_path?.trim();
      if (!gameId || !sportPath) return;

      this.onClientConfig({
        event: "client_config",
        game_id: gameId,
        sport_path: sportPath,
      });
    } catch {
      // Ignore non-JSON or unrelated client messages.
    }
  }
}
