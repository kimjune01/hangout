// --- Crypto helpers ---

const textEncoder = new TextEncoder();

async function exportKeyJwk(key) {
  return crypto.subtle.exportKey("jwk", key);
}

async function importKeyJwk(jwk, usages) {
  return crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    usages
  );
}

async function loadOrCreateKeyPair() {
  const stored = localStorage.getItem("hangout_keypair");
  if (stored) {
    const parsed = JSON.parse(stored);
    return {
      publicKey: await importKeyJwk(parsed.publicKey, ["verify"]),
      privateKey: await importKeyJwk(parsed.privateKey, ["sign"]),
      jwk: parsed,
    };
  }

  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );

  const jwk = {
    publicKey: await exportKeyJwk(keyPair.publicKey),
    privateKey: await exportKeyJwk(keyPair.privateKey),
  };

  localStorage.setItem("hangout_keypair", JSON.stringify(jwk));
  return { ...keyPair, jwk };
}

function publicKeyFingerprint(jwk) {
  const raw = JSON.stringify(jwk);
  let hash = 0;
  for (let i = 0; i < raw.length; i += 1)
    hash = (hash * 31 + raw.charCodeAt(i)) >>> 0;
  return hash.toString(16).padStart(8, "0").slice(-8);
}

// --- Scroll Hook ---
// Auto-scrolls to bottom on new messages. Detects scroll-lock when user
// scrolls up. Re-enables auto-scroll when user scrolls back to bottom.

const Scroll = {
  mounted() {
    this.autoScroll = true;
    this.el.scrollTop = this.el.scrollHeight;

    this.el.addEventListener("scroll", () => {
      const atBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 40;
      this.autoScroll = atBottom;
    });

    this.observer = new MutationObserver(() => {
      if (this.autoScroll) {
        requestAnimationFrame(() => {
          this.el.scrollTop = this.el.scrollHeight;
        });
      }
    });

    this.observer.observe(this.el, { childList: true, subtree: true });
  },

  updated() {
    if (this.autoScroll) {
      requestAnimationFrame(() => {
        this.el.scrollTop = this.el.scrollHeight;
      });
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

// --- Notifications Hook ---
// Three-step flow:
// 1. User sends first message → server pushes "ask_notifications" event
// 2. In-app banner asks "Get notified of new messages?" → user clicks Yes
// 3. Browser permission dialog fires
//
// After permission granted, notifications fire when tab is hidden.

const Notifications = {
  mounted() {
    this.enabled = false;
    this.hasSentMessage = false;

    // Step 1: server tells us to show the ask banner after first message sent
    this.handleEvent("hangout:ask_notifications", () => {
      if (!("Notification" in window)) return;
      if (Notification.permission === "granted") {
        this.enabled = true;
        return;
      }
      if (Notification.permission === "denied") return;

      // Show in-app banner
      this.showBanner();
    });

    // Incoming messages → fire notification if enabled and tab hidden
    this.handleEvent("hangout:message", (payload) => this.notify(payload));
  },

  showBanner() {
    const banner = document.createElement("div");
    banner.className = "notification-banner";
    banner.innerHTML = `
      <span>Get notified of new messages?</span>
      <button class="notif-yes">Yes</button>
      <button class="notif-no">No</button>
    `;
    banner.style.cssText =
      "position:fixed;bottom:4rem;left:50%;transform:translateX(-50%);" +
      "background:var(--panel-2);border:1px solid var(--border);border-radius:6px;" +
      "padding:0.5rem 1rem;display:flex;align-items:center;gap:0.75rem;" +
      "font-size:0.875rem;color:var(--text);z-index:100;";

    banner.querySelector(".notif-yes").style.cssText =
      "background:var(--accent);color:var(--bg);border:none;padding:0.25rem 0.75rem;" +
      "border-radius:4px;cursor:pointer;font-weight:600;";

    banner.querySelector(".notif-no").style.cssText =
      "background:none;border:1px solid var(--border);color:var(--muted);" +
      "padding:0.25rem 0.75rem;border-radius:4px;cursor:pointer;";

    banner.querySelector(".notif-yes").addEventListener("click", async () => {
      banner.remove();
      const perm = await Notification.requestPermission();
      if (perm === "granted") this.enabled = true;
    });

    banner.querySelector(".notif-no").addEventListener("click", () => {
      banner.remove();
    });

    document.body.appendChild(banner);

    // Auto-dismiss after 15 seconds
    setTimeout(() => banner.remove(), 15000);
  },

  notify(payload) {
    if (!this.enabled || !document.hidden) return;
    if (!("Notification" in window) || Notification.permission !== "granted") return;

    const title = payload.channel ? `#${payload.channel}` : "Hangout";
    const body = `${payload.from || "someone"}: ${(payload.body || "").slice(0, 100)}`;
    const notification = new Notification(title, { body, tag: title });
    notification.onclick = () => window.focus();
  },

  destroyed() {},
};

// --- Identity Hook ---
// Manages ECDSA P-256 keypair in localStorage. Sends public key to server
// on mount. Handles export/import/new via server events and window API.

const Identity = {
  async mounted() {
    if (!window.crypto?.subtle) return;

    const keyPair = await loadOrCreateKeyPair();
    const publicKey = JSON.stringify(keyPair.jwk.publicKey);

    this.pushEvent("identity_ready", {
      publicKey,
      fingerprint: publicKeyFingerprint(keyPair.jwk.publicKey),
    });

    // Server-initiated events
    this.handleEvent("export_identity", () => {
      const blob = new Blob([JSON.stringify(keyPair.jwk, null, 2)], {
        type: "application/json",
      });
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = "hangout-identity.json";
      link.click();
      URL.revokeObjectURL(link.href);
    });

    this.handleEvent("import_identity", () => {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".json";
      input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        const text = await file.text();
        try {
          const parsed = JSON.parse(text);
          // Validate keys are importable
          await importKeyJwk(parsed.publicKey, ["verify"]);
          await importKeyJwk(parsed.privateKey, ["sign"]);
          localStorage.setItem("hangout_keypair", JSON.stringify(parsed));
          window.location.reload();
        } catch (err) {
          console.error("Invalid identity file", err);
        }
      };
      input.click();
    });

    this.handleEvent("new_identity", () => {
      localStorage.removeItem("hangout_keypair");
      window.location.reload();
    });

    // Expose programmatic API
    window.hangoutIdentity = {
      export: () => this.el.dispatchEvent(new Event("export_identity")),
      import: async (file) => {
        const text = await file.text();
        const parsed = JSON.parse(text);
        await importKeyJwk(parsed.publicKey, ["verify"]);
        await importKeyJwk(parsed.privateKey, ["sign"]);
        localStorage.setItem("hangout_keypair", JSON.stringify(parsed));
        window.location.reload();
      },
      reset: () => {
        localStorage.removeItem("hangout_keypair");
        window.location.reload();
      },
      sign: async (message) => {
        const signature = await crypto.subtle.sign(
          { name: "ECDSA", hash: "SHA-256" },
          keyPair.privateKey,
          textEncoder.encode(message)
        );
        return btoa(String.fromCharCode(...new Uint8Array(signature)));
      },
    };
  },
};

// --- TTL Countdown Hook ---
// Client-side countdown timer. Server sends expires_at; client ticks locally.

const TTLCountdown = {
  mounted() {
    this.startCountdown();
  },

  updated() {
    this.startCountdown();
  },

  startCountdown() {
    if (this.interval) clearInterval(this.interval);

    const expiresAt = this.el.dataset.expiresAt;
    if (!expiresAt) return;

    const target = new Date(expiresAt).getTime();

    this.interval = setInterval(() => {
      const now = Date.now();
      const diff = Math.max(0, Math.floor((target - now) / 1000));

      if (diff <= 0) {
        this.el.textContent = "expired";
        clearInterval(this.interval);
        return;
      }

      const hours = Math.floor(diff / 3600);
      const minutes = Math.floor((diff % 3600) / 60);
      const seconds = diff % 60;

      if (hours > 0) {
        this.el.textContent = `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
      } else {
        this.el.textContent = `${minutes}:${String(seconds).padStart(2, "0")}`;
      }
    }, 1000);
  },

  destroyed() {
    if (this.interval) clearInterval(this.interval);
  },
};

// --- MessageForm Hook ---
// Clears input on submit. Also handles notification events (moved from Notifications
// hook since this is the primary interactive element on the page).

const MessageForm = {
  mounted() {
    this.notificationsEnabled = false;

    // Clear input on submit
    this.el.addEventListener("submit", () => {
      const input = this.el.querySelector("input[name=body]");
      if (input) {
        requestAnimationFrame(() => { input.value = ""; });
      }
    });

    // Notification events
    this.handleEvent("hangout:ask_notifications", () => {
      if (!("Notification" in window)) return;
      if (Notification.permission === "granted") { this.notificationsEnabled = true; return; }
      if (Notification.permission === "denied") return;
      Notifications.showBanner.call(this);
    });

    this.handleEvent("hangout:message", (payload) => {
      if (!this.notificationsEnabled || !document.hidden) return;
      if (Notification.permission !== "granted") return;
      const title = payload.channel ? `#${payload.channel}` : "Hangout";
      const body = `${payload.from || "someone"}: ${(payload.body || "").slice(0, 100)}`;
      const n = new Notification(title, { body, tag: title });
      n.onclick = () => window.focus();
    });
  },
};

export const Hooks = { Scroll, Notifications, MessageForm, Identity, TTLCountdown };
