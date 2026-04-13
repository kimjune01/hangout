import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { Hooks } from "./hooks";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Connection status banner + auto-reload on deploy
const connBanner = document.getElementById("connection-status");
let disconnectedAt = null;
const RELOAD_MIN_DISCONNECT_MS = 2000;
const RELOAD_COOLDOWN_MS = 30000;
const RELOAD_COOLDOWN_KEY = "hangout_last_reload";

if (connBanner) {
  window.addEventListener("phx:page-loading-start", (info) => {
    if (info.detail?.kind === "error" || info.detail?.kind === "initial") {
      connBanner.classList.add("visible");
      if (!disconnectedAt) disconnectedAt = Date.now();
    }
  });
  window.addEventListener("phx:page-loading-stop", () => {
    connBanner.classList.remove("visible");
    if (disconnectedAt && (Date.now() - disconnectedAt) > RELOAD_MIN_DISCONNECT_MS) {
      const lastReload = parseInt(localStorage.getItem(RELOAD_COOLDOWN_KEY) || "0", 10);
      if (Date.now() - lastReload > RELOAD_COOLDOWN_MS) {
        localStorage.setItem(RELOAD_COOLDOWN_KEY, String(Date.now()));
        window.location.reload();
      }
    }
    disconnectedAt = null;
  });
}

// iOS keyboard viewport fix: set --vvh so fixed elements respect the keyboard
if (window.visualViewport) {
  const setVvh = () => {
    document.documentElement.style.setProperty(
      "--vvh",
      `${window.visualViewport.height}px`
    );
  };
  window.visualViewport.addEventListener("resize", setVvh);
  setVvh();
}

// Expose for debugging
window.liveSocket = liveSocket;
