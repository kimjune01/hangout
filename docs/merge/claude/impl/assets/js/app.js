import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { Scroll, Notifications, Identity, TTLCountdown } from "./hooks";

const Hooks = {
  Scroll,
  Notifications,
  Identity,
  TTLCountdown,
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

liveSocket.connect();

// Expose for debugging
window.liveSocket = liveSocket;
