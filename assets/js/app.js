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
let wasDisconnected = false;

if (connBanner) {
  window.addEventListener("phx:page-loading-start", (info) => {
    if (info.detail?.kind === "error" || info.detail?.kind === "initial") {
      connBanner.classList.add("visible");
      wasDisconnected = true;
    }
  });
  window.addEventListener("phx:page-loading-stop", () => {
    connBanner.classList.remove("visible");
    // If we reconnected after a disconnect, the server likely restarted.
    // Reload to pick up new JS/HTML.
    if (wasDisconnected) {
      window.location.reload();
    }
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
