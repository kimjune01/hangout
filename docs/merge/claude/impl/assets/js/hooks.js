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

    // MutationObserver to detect new child elements (messages)
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
// Requests browser notification permission on first message when not focused.
// Fires Notification API calls for messages received while tab is hidden.

const Notifications = {
  mounted() {
    this.permissionAsked = false;

    this.handleEvent("new_message_notification", (payload) => {
      if (document.hidden) {
        if (!this.permissionAsked && Notification.permission === "default") {
          this.permissionAsked = true;
          Notification.requestPermission();
          return;
        }

        if (Notification.permission === "granted") {
          new Notification(`#${payload.channel}`, {
            body: `${payload.nick}: ${payload.body.slice(0, 100)}`,
            tag: payload.channel,
          });
        }
      }
    });

    // Also fire for any new messages via DOM observation
    this._visibilityHandler = () => {
      // Nothing needed on visibility change itself
    };
    document.addEventListener("visibilitychange", this._visibilityHandler);
  },

  destroyed() {
    document.removeEventListener("visibilitychange", this._visibilityHandler);
  },
};

// --- Identity Hook ---
// Manages ECDSA P-256 keypair in localStorage. Sends public key to server
// on mount. Handles export/import.

const Identity = {
  async mounted() {
    const stored = localStorage.getItem("hangout_keypair");

    if (stored) {
      try {
        const keypair = JSON.parse(stored);
        this.pushEvent("set_public_key", {
          public_key: keypair.publicKey,
        });
      } catch (e) {
        await this.generateAndStore();
      }
    } else {
      await this.generateAndStore();
    }

    // Listen for export/import events
    this.handleEvent("export_identity", () => {
      const stored = localStorage.getItem("hangout_keypair");
      if (stored) {
        const blob = new Blob([stored], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "hangout-identity.json";
        a.click();
        URL.revokeObjectURL(url);
      }
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
          const keypair = JSON.parse(text);
          if (keypair.publicKey && keypair.privateKey) {
            localStorage.setItem("hangout_keypair", text);
            this.pushEvent("set_public_key", {
              public_key: keypair.publicKey,
            });
          }
        } catch (err) {
          console.error("Invalid identity file", err);
        }
      };
      input.click();
    });

    this.handleEvent("new_identity", async () => {
      await this.generateAndStore();
    });
  },

  async generateAndStore() {
    try {
      const keyPair = await crypto.subtle.generateKey(
        { name: "ECDSA", namedCurve: "P-256" },
        true,
        ["sign", "verify"]
      );

      const publicKeyJwk = await crypto.subtle.exportKey(
        "jwk",
        keyPair.publicKey
      );
      const privateKeyJwk = await crypto.subtle.exportKey(
        "jwk",
        keyPair.privateKey
      );

      const data = {
        publicKey: JSON.stringify(publicKeyJwk),
        privateKey: JSON.stringify(privateKeyJwk),
      };

      localStorage.setItem("hangout_keypair", JSON.stringify(data));
      this.pushEvent("set_public_key", { public_key: data.publicKey });
    } catch (e) {
      console.error("Failed to generate keypair:", e);
    }
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

export { Scroll, Notifications, Identity, TTLCountdown };
