import type { WebSocket } from "ws";
import { WebSocketServer } from "ws";
import type { AdCloudEvent } from "./types.js";

export class WebSocketHub {
  private readonly wss: WebSocketServer;
  private clients = new Set<WebSocket>();

  constructor(port: number) {
    this.wss = new WebSocketServer({ port });
    this.wss.on("connection", (socket) => {
      this.clients.add(socket);
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
}
