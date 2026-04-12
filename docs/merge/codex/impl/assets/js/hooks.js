const textEncoder = new TextEncoder();

async function exportKey(key) {
  const jwk = await crypto.subtle.exportKey("jwk", key);
  return jwk;
}

async function importKey(jwk, usages) {
  return crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, true, usages);
}

async function loadOrCreateKeyPair() {
  const stored = localStorage.getItem("hangout_keypair");
  if (stored) {
    const parsed = JSON.parse(stored);
    return {
      publicKey: await importKey(parsed.publicKey, ["verify"]),
      privateKey: await importKey(parsed.privateKey, ["sign"]),
      jwk: parsed
    };
  }

  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"]
  );

  const jwk = {
    publicKey: await exportKey(keyPair.publicKey),
    privateKey: await exportKey(keyPair.privateKey)
  };

  localStorage.setItem("hangout_keypair", JSON.stringify(jwk));
  return { ...keyPair, jwk };
}

function publicKeyFingerprint(jwk) {
  const raw = JSON.stringify(jwk);
  let hash = 0;
  for (let i = 0; i < raw.length; i += 1) hash = (hash * 31 + raw.charCodeAt(i)) >>> 0;
  return hash.toString(16).padStart(8, "0").slice(-8);
}

export const Hooks = {
  Scroll: {
    mounted() {
      this.locked = false;
      this.el.addEventListener("scroll", () => {
        const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight;
        this.locked = distance > 80;
      });
      this.scroll();
    },
    updated() {
      if (!this.locked) this.scroll();
    },
    scroll() {
      this.el.scrollTop = this.el.scrollHeight;
    }
  },

  Notifications: {
    mounted() {
      this.permissionRequested = false;
      this.handleEvent("hangout:message", (payload) => this.notify(payload));
      this.handleEvent("hangout:buffer_cleared", () => {});
      this.el.addEventListener("click", async () => {
        if ("Notification" in window && Notification.permission === "default") {
          await Notification.requestPermission();
        }
      });
    },
    async notify(payload) {
      if (!("Notification" in window)) return;
      if (Notification.permission === "default" && !this.permissionRequested) {
        this.permissionRequested = true;
        await Notification.requestPermission();
      }
      if (Notification.permission !== "granted" || !document.hidden) return;

      const title = payload.channel || this.el.dataset.channel || "Hangout";
      const body = `${payload.from}: ${(payload.body || "").slice(0, 100)}`;
      const notification = new Notification(title, { body, tag: title });
      notification.onclick = () => window.focus();
    }
  },

  Identity: {
    async mounted() {
      if (!window.crypto?.subtle) return;
      const keyPair = await loadOrCreateKeyPair();
      const publicKey = JSON.stringify(keyPair.jwk.publicKey);
      this.pushEvent("identity_ready", {
        publicKey,
        fingerprint: publicKeyFingerprint(keyPair.jwk.publicKey)
      });

      window.hangoutIdentity = {
        export: () => {
          const blob = new Blob([JSON.stringify(keyPair.jwk, null, 2)], { type: "application/json" });
          const link = document.createElement("a");
          link.href = URL.createObjectURL(blob);
          link.download = "hangout-identity.json";
          link.click();
          URL.revokeObjectURL(link.href);
        },
        import: async (file) => {
          const text = await file.text();
          const parsed = JSON.parse(text);
          await importKey(parsed.publicKey, ["verify"]);
          await importKey(parsed.privateKey, ["sign"]);
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
        }
      };
    }
  }
};
