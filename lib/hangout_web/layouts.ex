defmodule HangoutWeb.Layouts do
  use HangoutWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Hangout</title>
        <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🫧</text></svg>" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:ital,wght@0,400;0,500;0,600;1,400&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet" />
        <script defer phx-track-static src="/assets/app.js"></script>
        <style>
          :root, [data-theme="dark"] {
            color-scheme: dark;
            --bg: #0a0a0a;
            --panel: #0e0e0e;
            --panel-2: #161916;
            --border: #1e4d1e;
            --text: #d0d0d0;
            --muted: #6abf5e;
            --dim: #2d7a2d;
            --accent: #39ff14;
            --accent-2: #7ecb20;
            --danger: #ff6b63;
            --success: #39ff14;
            --font-ui: "IBM Plex Sans", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            --font-mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            --btn-text: var(--bg);
            --sp-1: 0.25rem;
            --sp-2: 0.5rem;
            --sp-3: 0.75rem;
            --sp-4: 1rem;
            --sp-6: 1.5rem;
            --sp-8: 2rem;
          }

          [data-theme="light"] {
            color-scheme: light;
            --bg: #f5f3ef;
            --panel: #ffffff;
            --panel-2: #eae7e1;
            --border: #c4bfb7;
            --text: #1a1918;
            --muted: #5a554f;
            --dim: #6e6860;
            --accent: #0a8a08;
            --accent-2: #8a6508;
            --danger: #c62828;
            --success: #0a8a08;
            --btn-text: #ffffff;
          }

          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

          /* --- Focus indicators --- */
          :focus-visible {
            outline: 2px solid var(--accent);
            outline-offset: 2px;
          }
          input:focus-visible { outline: none; }

          /* --- Reduced motion --- */
          @media (prefers-reduced-motion: reduce) {
            *, *::before, *::after {
              animation-duration: 0.01ms !important;
              animation-iteration-count: 1 !important;
              transition-duration: 0.01ms !important;
            }
          }

          body {
            font-family: var(--font-ui);
            background: var(--bg);
            background-image: radial-gradient(ellipse at 15% 85%, #0b150b 0%, transparent 45%),
                              radial-gradient(ellipse at 85% 15%, #110a13 0%, transparent 45%),
                              radial-gradient(ellipse at 50% 50%, #0a0a0a 0%, #080808 100%);
            background-attachment: fixed;
            color: var(--text);
            min-height: 100vh;
            font-size: 16px;
            line-height: 1.5;
          }

          /* --- Layout --- */
          .container { max-width: 960px; margin: 0 auto; padding: var(--sp-2) var(--sp-4); height: var(--vvh, 100vh); display: flex; flex-direction: column; }
          .room-layout { display: flex; flex: 1; gap: var(--sp-4); min-height: 0; }
          .messages-panel { flex: 1; display: flex; flex-direction: column; min-width: 0; }

          /* --- Messages --- */
          .messages {
            flex: 1;
            overflow-y: auto;
            padding: var(--sp-3) var(--sp-4);
            background: var(--panel);
            border-radius: 6px;
            border: 1px solid var(--border);
          }
          @keyframes msg-in { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: translateY(0); } }
          .message { padding: 3px 0; line-height: 1.5; font-size: 1rem; max-width: 78ch; animation: msg-in 0.15s ease-out; }
          .message .nick { font-family: var(--font-mono); font-weight: 600; font-size: 0.9375rem; }
          .message .time { font-family: var(--font-mono); color: var(--dim); font-size: 0.8125rem; margin-right: var(--sp-2); }
          .message.system {
            color: var(--muted);
            font-style: normal;
            border-left: 2px solid var(--border);
            padding-left: var(--sp-2);
            font-size: 0.9375rem;
          }
          @keyframes gentle-pulse { 0%, 100% { opacity: 0.3; } 50% { opacity: 0.5; } }
          .message.system:only-child { animation: gentle-pulse 3s ease-in-out infinite; }
          .message.action { color: var(--accent); }
          .message.notice { color: var(--accent-2); }
          .message.agent {
            border-left: 2px solid color-mix(in srgb, var(--accent) 55%, transparent);
            padding-left: var(--sp-2);
            background: color-mix(in srgb, var(--accent) 4%, transparent);
          }

          /* --- Markdown in messages --- */
          .md-body { display: inline; }
          .md-body p { display: inline; margin: 0; }
          .md-body p + p { display: block; margin-top: 0.25rem; }
          .md-body code { font-family: var(--font-mono); background: var(--panel-2); padding: 0.1rem 0.3rem; border-radius: 3px; font-size: 0.875rem; }
          .md-body pre { background: var(--panel-2); border: 1px solid var(--border); border-radius: 4px; padding: 0.5rem 0.75rem; margin: 0.25rem 0; overflow-x: auto; }
          .md-body pre code { background: none; padding: 0; font-size: 0.8125rem; }
          .md-body a { color: var(--accent); }
          .md-body strong { color: var(--text); font-weight: 600; }
          .md-body em { color: var(--muted); }
          .md-body blockquote { border-left: 2px solid var(--border); padding-left: 0.5rem; color: var(--muted); margin: 0.25rem 0; }
          .md-body ul, .md-body ol { margin: 0.25rem 0 0.25rem 1.5rem; }
          .md-body h1, .md-body h2, .md-body h3, .md-body h4, .md-body h5, .md-body h6 { font-size: 1rem; font-weight: 600; margin: 0.25rem 0; }
          .copy-md, .forward-btn {
            background: none;
            border: none;
            color: var(--dim);
            font-family: var(--font-mono);
            font-size: 0.6875rem;
            cursor: pointer;
            padding: 0 0.25rem;
            margin-left: 0.25rem;
            vertical-align: baseline;
            opacity: 0;
            transition: opacity 0.15s;
          }
          .message:hover .copy-md, .message:hover .forward-btn { opacity: 1; }
          .copy-md:hover, .forward-btn:hover { color: var(--accent); }

          /* --- Collapse long messages --- */
          .message.collapsed {
            max-height: 4.5em; /* 3 lines × 1.5 line-height */
            overflow: hidden;
            -webkit-mask-image: linear-gradient(to bottom, black 60%, transparent 100%);
            mask-image: linear-gradient(to bottom, black 60%, transparent 100%);
          }
          .message.collapsed + .collapse-toggle { margin-top: -0.25rem; }
          .collapse-toggle {
            background: none;
            border: none;
            color: var(--dim);
            font-size: 0.75rem;
            font-family: var(--font-mono);
            cursor: pointer;
            padding: 0;
          }
          .collapse-toggle:hover { color: var(--accent); }

          /* --- Member toggle + drawer (inside messages panel) --- */
          .member-toggle {
            position: absolute;
            top: 0.5rem;
            right: 0.5rem;
            background: var(--panel-2);
            border: 1px solid var(--border);
            color: var(--muted);
            padding: 0.5rem 0.75rem;
            border-radius: 4px;
            font-size: 0.75rem;
            font-family: var(--font-mono);
            cursor: pointer;
            z-index: 5;
            min-height: 44px;
            min-width: 44px;
          }
          @keyframes count-flash { 0% { color: var(--accent); } 100% { color: var(--muted); } }
          .member-toggle { transition: color 0.3s ease; }
          .member-toggle:hover { color: var(--text); }
          .member-drawer-backdrop {
            position: fixed;
            inset: 0;
            z-index: 9;
          }
          .member-drawer {
            position: absolute;
            top: 2rem;
            right: var(--sp-2);
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: var(--sp-2) var(--sp-3);
            max-height: 50%;
            overflow-y: auto;
            z-index: 10;
            min-width: 140px;
          }
          .nick-entry { padding: 3px 0; font-size: 0.875rem; display: flex; align-items: center; gap: 0.25rem; }
          .nick-entry .bot-badge { font-size: 0.6875rem; color: var(--muted); font-family: var(--font-mono); }
          .nick-entry .op-badge { color: var(--accent-2); font-family: var(--font-mono); }

          /* --- Input bar --- */
          .input-bar { display: flex; align-items: center; gap: 0; padding: var(--sp-2) 0; padding-bottom: calc(var(--sp-2) + env(safe-area-inset-bottom, 0px)); }
          .input-bar.draft-mode {
            border: 1px solid color-mix(in srgb, var(--accent) 70%, var(--border));
            border-radius: 6px;
            padding-left: var(--sp-2);
            padding-right: var(--sp-2);
            background: color-mix(in srgb, var(--accent) 8%, transparent);
          }
          @keyframes draft-arrive {
            0%   { box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent) 55%, transparent); }
            60%  { box-shadow: 0 0 0 6px color-mix(in srgb, var(--accent) 0%, transparent); }
            100% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent) 0%, transparent); }
          }
          .input-bar.draft-arriving { animation: draft-arrive 0.6s ease-out; }
          @media (prefers-reduced-motion: reduce) {
            .input-bar.draft-arriving { animation: none; }
          }
          .input-bar.draft-mode .nick-label { display: none; }
          .input-bar .nick-label {
            font-family: var(--font-mono);
            color: var(--muted);
            padding: var(--sp-2) 0;
            font-size: 0.875rem;
            white-space: nowrap;
            user-select: none;
          }
          .input-bar .nick-label::after { content: " >"; color: var(--dim); }
          .input-bar input {
            flex: 1;
            background: transparent;
            border: none;
            border-bottom: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
            color: var(--text);
            padding: var(--sp-2) var(--sp-2);
            font-size: 1rem;
            font-family: var(--font-ui);
            outline: none;
            transition: border-bottom-color 0.2s ease;
          }
          .input-bar input:focus { border-bottom-color: var(--accent); }
          .input-bar.draft-mode input { border-bottom-color: var(--accent); }
          .draft-label {
            color: var(--accent);
            font-family: var(--font-mono);
            font-size: 0.75rem;
            font-weight: 600;
            margin-right: var(--sp-2);
            white-space: nowrap;
          }
          .draft-label::after { content: " >"; color: var(--dim); }
          .draft-discard {
            color: var(--dim);
            font-family: var(--font-mono);
            font-size: 0.875rem;
          }
          .draft-discard:hover { color: var(--danger); }
          .voice-btn {
            background: none;
            border: 1px solid var(--border);
            color: var(--dim);
            padding: 0.5rem 0.75rem;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.75rem;
            font-family: var(--font-mono);
            margin-right: 0.25rem;
            min-height: 44px;
          }
          .voice-btn:hover { color: var(--text); border-color: var(--muted); }
          .voice-btn.voice-active { color: var(--accent); border-color: var(--accent); }
          .voice-btn.voice-speaking { box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 40%, transparent); }
          @keyframes voice-pulse { 0%, 100% { box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent); } 50% { box-shadow: 0 0 0 5px color-mix(in srgb, var(--accent) 50%, transparent); } }
          .voice-btn.voice-speaking { animation: voice-pulse 0.6s ease-in-out infinite; }
          .input-bar input::placeholder { color: var(--dim); }
          .input-bar button {
            background: none;
            color: var(--dim);
            border: none;
            padding: var(--sp-2) var(--sp-3);
            cursor: pointer;
            font-size: 0.875rem;
            min-height: 44px;
          }
          .input-bar button:hover { color: var(--accent); }
          .input-bar button[type="submit"] { transition: transform 0.1s ease; }
          .input-bar button[type="submit"]:active { transform: scale(1.3); }
          .send-error { color: var(--danger); font-size: 0.75rem; padding: 0.125rem 0; opacity: 0.8; }

          /* --- Header --- */
          .header {
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            padding: var(--sp-2) 0;
            margin-bottom: var(--sp-2);
          }
          .header h1 { font-family: var(--font-mono); font-size: 1.125rem; color: var(--text); font-weight: 600; }
          .header .topic { font-size: 0.875rem; color: var(--muted); margin-left: var(--sp-4); font-weight: normal; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .header .badges { display: flex; gap: var(--sp-2); align-items: center; font-size: 0.8125rem; color: var(--muted); flex-shrink: 0; }
          .header .lock-badge { color: var(--accent-2); }
          .header .ttl-badge { color: var(--accent); }
          .header .member-count { font-family: var(--font-mono); font-size: 0.8125rem; }
          .mod-link-btn {
            background: none;
            border: 1px solid var(--border);
            color: var(--muted);
            font-family: var(--font-mono);
            font-size: 0.6875rem;
            padding: 0.25rem 0.5rem;
            border-radius: 4px;
            cursor: pointer;
            white-space: nowrap;
          }
          .mod-link-btn:hover { color: var(--accent); border-color: var(--accent); }
          .mod-link-dismiss {
            background: none;
            border: none;
            color: var(--dim);
            cursor: pointer;
            font-size: 0.75rem;
            padding: 0.25rem;
          }
          .mod-link-dismiss:hover { color: var(--text); }

          /* --- Mod controls --- */
          .mod-controls {
            margin-top: 0.25rem;
            font-size: 0.75rem;
          }
          .mod-controls summary {
            color: var(--muted);
            cursor: pointer;
            font-size: 0.75rem;
            user-select: none;
            list-style: none;
            font-family: var(--font-mono);
            opacity: 0.5;
          }
          .mod-controls summary:hover { color: var(--text); }
          .mod-controls summary::-webkit-details-marker { display: none; }
          .mod-controls .mod-buttons {
            display: flex;
            gap: 0.25rem;
            margin-top: 0.25rem;
            flex-wrap: wrap;
          }
          .mod-controls button {
            background: var(--panel-2);
            color: var(--muted);
            border: 1px solid var(--border);
            padding: 0.5rem 0.75rem;
            border-radius: 4px;
            font-size: 0.75rem;
            cursor: pointer;
            min-height: 44px;
          }
          .mod-controls button:hover { background: var(--border); color: var(--text); }
          .mod-controls button.danger { border-color: var(--danger); color: var(--danger); }
          .mod-controls button.danger:hover { background: var(--danger); color: var(--btn-text); }

          /* --- Entry content (inside messages panel before join) --- */
          .entry-content {
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            width: 100%;
            min-height: 100%;
            padding: var(--sp-8) var(--sp-4);
            text-align: center;
            animation: fade-in 0.2s ease;
          }
          .messages:has(.entry-content) { display: flex; }
          .entry-content.fading-out { animation: fade-out 0.2s ease-out forwards; }
          @keyframes fade-out { from { opacity: 1; } to { opacity: 0; } }
          .joining-state { font-family: var(--font-mono); font-size: 0.875rem; color: var(--dim); animation: gentle-pulse 2s ease-in-out infinite; }

          /* --- Nick prompt (kept for room-ended state) --- */
          .nick-prompt { text-align: center; padding: 6rem 1rem 4rem; }
          .nick-prompt .room-name {
            font-family: var(--font-mono);
            font-size: 2rem;
            color: var(--accent);
            font-weight: 600;
            margin-bottom: 0.5rem;
          }
          .nick-prompt .room-info { color: var(--muted); font-size: 0.9375rem; margin-bottom: 2rem; }
          .guest-list {
            display: flex;
            flex-wrap: wrap;
            justify-content: center;
            gap: 0.25rem 0.75rem;
            margin-bottom: var(--sp-8);
            font-family: var(--font-mono);
            font-size: 0.9375rem;
            width: 100%;
            max-width: 28rem;
            margin-left: auto;
            margin-right: auto;
          }
          .guest-list .guest-label {
            width: 100%;
            text-align: center;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--dim);
            margin-bottom: 0.25rem;
          }
          .guest-list .guest {
            max-width: 10rem;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
          }
          .guest-list .more { color: var(--dim); }
          .join-form {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 1rem;
          }
          .nick-prompt input {
            background: transparent;
            border: none;
            border-bottom: 2px solid var(--border);
            color: var(--text);
            padding: 0.5rem 0.5rem;
            font-size: 1rem;
            width: 12rem;
            text-align: center;
            font-family: var(--font-mono);
            outline: none;
          }
          .nick-prompt input:focus { border-bottom-color: var(--accent); }
          .nick-prompt input::placeholder { color: var(--dim); }
          .nick-prompt button {
            background: var(--accent);
            color: var(--btn-text);
            border: none;
            padding: 0.6rem 2rem;
            border-radius: 4px;
            cursor: pointer;
            font-size: 1rem;
            font-weight: 600;
            display: block;
            margin: 1.5rem auto 0;
          }
          .nick-prompt button:hover { opacity: 0.9; }

          /* --- Social contract --- */
          .entry-join-form {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 0.75rem;
            margin: var(--sp-8) auto var(--sp-4);
            max-width: 16rem;
            width: 100%;
          }
          .entry-nick-input {
            background: transparent;
            border: none;
            border-bottom: 2px solid var(--border);
            color: var(--text);
            padding: 0.5rem 0.25rem;
            font-size: 1.125rem;
            font-family: var(--font-mono);
            text-align: center;
            width: 100%;
            outline: none;
          }
          .entry-nick-input:focus { border-bottom-color: var(--accent); }
          .entry-nick-input::placeholder { color: var(--dim); }
          .entry-join-btn {
            background: var(--accent);
            color: var(--btn-text);
            border: none;
            padding: 0.75rem 2rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 1rem;
            font-weight: 600;
            width: 100%;
            min-height: 48px;
          }
          .entry-join-btn:hover { opacity: 0.9; }
          .social-contract {
            font-size: 0.8125rem;
            color: var(--dim);
            text-align: center;
            margin-top: var(--sp-8);
            max-width: 28rem;
            margin-left: auto;
            margin-right: auto;
            line-height: 1.5;
          }
          .social-contract p + p { margin-top: var(--sp-1); }

          /* --- Home form --- */
          .home-form { max-width: 24rem; margin: 6rem auto; text-align: center; }
          .home-form h1 { font-family: var(--font-mono); font-size: 2.5rem; color: var(--accent); margin-bottom: 0.25rem; font-weight: 700; }
          .home-form .tagline { color: var(--muted); margin-bottom: 2.5rem; font-size: 1rem; }
          .home-form input {
            background: transparent;
            border: none;
            border-bottom: 1px solid var(--border);
            color: var(--text);
            padding: 0.75rem 0.5rem;
            font-size: 1rem;
            width: 100%;
            margin-bottom: 0.75rem;
            outline: none;
          }
          .home-form input:focus { border-bottom-color: var(--accent); }
          .home-form input::placeholder { color: var(--dim); }
          .home-form select {
            background: var(--panel);
            border: 1px solid var(--border);
            color: var(--text);
            padding: 0.6rem 0.5rem;
            border-radius: 4px;
            font-size: 0.9375rem;
            width: 100%;
            margin-bottom: 1rem;
          }
          .home-form button {
            background: var(--accent);
            color: var(--btn-text);
            border: none;
            padding: 0.6rem 2rem;
            border-radius: 4px;
            cursor: pointer;
            font-size: 1rem;
            font-weight: 600;
          }
          .home-form button:hover { opacity: 0.9; }

          /* --- Flash messages --- */
          .flash { padding: var(--sp-2) var(--sp-3); border-radius: 4px; font-size: 0.875rem; margin-bottom: var(--sp-2); }
          .flash.error { background: color-mix(in srgb, var(--danger) 10%, transparent); border: 1px solid var(--danger); color: var(--danger); }
          .flash.info { background: color-mix(in srgb, var(--accent) 10%, transparent); border: 1px solid var(--accent); color: var(--accent); }

          /* --- Kick button --- */
          .kick-btn { background: none; border: none; color: var(--danger); cursor: pointer; font-size: 0.6875rem; margin-left: auto; padding: 0.5rem; min-height: 44px; min-width: 44px; display: inline-flex; align-items: center; justify-content: center; opacity: 0.5; }
          .kick-btn:hover { opacity: 1; }

          /* --- Mod link --- */
          .mod-link-banner {
            background: var(--panel-2);
            padding: var(--sp-2) var(--sp-3);
            border-radius: 4px;
            margin-bottom: var(--sp-2);
            font-size: 0.8125rem;
          }
          .mod-link-banner .label { color: var(--accent-2); }
          .mod-link-banner code { font-family: var(--font-mono); color: var(--accent); word-break: break-all; font-size: 0.75rem; }

          /* --- Room ended state --- */
          .room-ended { text-align: center; padding: 6rem 1rem; }
          .room-ended h2 { font-family: var(--font-mono); color: var(--muted); margin-bottom: 1rem; }
          .room-ended a { color: var(--accent); }

          /* --- Info menu --- */
          .info-btn {
            background: none;
            border: none;
            color: var(--muted);
            cursor: pointer;
            font-size: 1.125rem;
            padding: 0.25rem;
            line-height: 1;
          }
          .info-btn:hover { color: var(--text); }
          .info-backdrop {
            position: fixed;
            inset: 0;
            z-index: 99;
          }
          .info-modal {
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: var(--sp-4);
            z-index: 100;
            min-width: 280px;
            max-width: 360px;
            width: 90vw;
            animation: modal-fade-in 0.15s ease-out;
          }
          .info-modal h3 {
            font-family: var(--font-mono);
            font-size: 0.875rem;
            color: var(--muted);
            margin-bottom: var(--sp-3);
            text-transform: uppercase;
            letter-spacing: 0.05em;
          }
          .info-modal ul {
            list-style: none;
            padding: 0;
            margin: 0;
          }
          .info-modal li {
            padding: 0.5rem 0;
            border-bottom: 1px solid var(--border);
            font-size: 0.9375rem;
          }
          .info-modal li:last-child { border-bottom: none; }
          .info-modal a {
            color: var(--accent);
            text-decoration: none;
          }
          .info-modal a:hover { text-decoration: underline; }
          .info-modal button:not(.agent-tab):not(.agent-invite-btn):not(.agent-copy-btn):not(.agent-disconnect-btn) {
            background: none;
            border: none;
            color: var(--accent);
            cursor: pointer;
            font-size: 0.9375rem;
            padding: 0;
            font-family: inherit;
          }
          .info-modal button:not(.agent-tab):not(.agent-invite-btn):not(.agent-copy-btn):not(.agent-disconnect-btn):hover { text-decoration: underline; }
          .info-modal .hint {
            color: var(--dim);
            font-size: 0.75rem;
            margin-top: 0.125rem;
          }
          .info-modal .agent-invite-actions { margin-top: 0.25rem; }
          .agent-url-row { display: flex; align-items: center; gap: 0.25rem; margin-top: 0.25rem; border: 1px solid var(--border); border-radius: 4px; padding: 0.25rem 0.375rem; }
          .agent-url { font-family: var(--font-mono); font-size: 0.6875rem; color: var(--accent); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; user-select: all; }
          .agent-copy-btn { background: none; border: none; color: var(--dim); cursor: pointer; font-size: 0.875rem; padding: 0.25rem; min-height: 44px; min-width: 44px; display: inline-flex; align-items: center; justify-content: center; }
          .agent-copy-btn:hover { color: var(--accent); }
          .agent-status { display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 0; margin-top: 0.25rem; font-size: 0.8125rem; font-family: var(--font-mono); color: var(--dim); }
          .agent-status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dim); flex-shrink: 0; animation: status-pulse 2s ease-in-out infinite; }
          .agent-status.connected .agent-status-dot { background: var(--accent); animation: none; }
          .agent-status.connected { color: var(--accent); }
          @keyframes status-pulse { 0%, 100% { opacity: 0.3; } 50% { opacity: 0.7; } }
          .agent-modal { min-width: 240px; }
          .agent-tabs { display: flex; gap: 1rem; margin-bottom: 0.75rem; border-bottom: 1px solid var(--border); }
          .agent-tab { background: none; border: none; border-bottom: 3px solid transparent; color: var(--muted); font-family: var(--font-mono); font-size: 0.8125rem; padding: 0.375rem 0; cursor: pointer; min-height: 44px; transition: color 0.2s, border-color 0.2s; }
          .agent-tab:hover { color: var(--text); }
          .agent-tab.active { color: var(--accent); border-bottom-color: var(--accent); }
          .agent-panel { min-height: 12rem; }
          .agent-section { margin-bottom: 0.75rem; }
          .agent-section:last-of-type { margin-bottom: 0.5rem; }
          .agent-section-header { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 0.125rem; }
          .agent-section-label { font-family: var(--font-mono); font-size: 0.75rem; color: var(--dim); text-transform: uppercase; letter-spacing: 0.05em; }
          .agent-active-mode { font-family: var(--font-mono); font-size: 0.8125rem; color: var(--accent); font-weight: 600; }
          .agent-active-mode.danger { color: var(--danger); }
          .freedom-slider { width: 100%; accent-color: var(--accent); cursor: pointer; margin: 0.125rem 0; }
          .freedom-slider.unleashed { accent-color: var(--danger); }
          .freedom-slider:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
          .agent-invite-btn { background: none; color: var(--accent); border: 1px solid var(--accent); padding: 0.5rem 1rem; border-radius: 4px; cursor: pointer; font-size: 0.8125rem; font-family: var(--font-mono); width: 100%; min-height: 44px; }
          .agent-invite-btn:hover { background: var(--accent); color: var(--btn-text); }
          .agent-disconnect-btn { background: none; border: 1px solid var(--danger); color: var(--danger); padding: 0.4rem 0.75rem; border-radius: 4px; cursor: pointer; font-size: 0.75rem; width: 100%; min-height: 44px; }
          .agent-url-row .agent-copy-btn { min-height: unset; min-width: unset; padding: 0.25rem; }
          .agent-disconnect-btn:hover { background: var(--danger); color: var(--btn-text); }
          .agent-toast {
            position: fixed;
            bottom: 4rem;
            left: 50%;
            transform: translateX(-50%);
            background: var(--panel-2);
            border: 1px solid var(--accent);
            color: var(--accent);
            padding: 0.5rem 1rem;
            border-radius: 6px;
            font-size: 0.875rem;
            font-family: var(--font-mono);
            z-index: 200;
            animation: toast-in-out 2s ease-in-out forwards;
          }
          @keyframes toast-in-out {
            0% { opacity: 0; transform: translateX(-50%) translateY(8px); }
            15% { opacity: 1; transform: translateX(-50%) translateY(0); }
            85% { opacity: 1; transform: translateX(-50%) translateY(0); }
            100% { opacity: 0; transform: translateX(-50%) translateY(-4px); }
          }

          @keyframes fade-in {
            from { opacity: 0; transform: translateY(4px); }
            to { opacity: 1; transform: translateY(0); }
          }

          @keyframes modal-fade-in {
            from { opacity: 0; transform: translate(-50%, -50%) scale(0.98); }
            to { opacity: 1; transform: translate(-50%, -50%) scale(1); }
          }

          @keyframes msg-enter {
            from { opacity: 0; transform: translateY(2px); }
            to { opacity: 1; transform: translateY(0); }
          }

          /* --- Reconnection banner --- */
          #connection-status {
            display: none;
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            padding: var(--sp-2) var(--sp-4);
            background: color-mix(in srgb, var(--accent-2) 15%, var(--panel));
            border-top: 2px solid var(--accent-2);
            color: var(--accent-2);
            font-size: 0.875rem;
            text-align: center;
            z-index: 200;
          }
          #connection-status.visible { display: block; }

          /* --- Message entry animation --- */
          .message {
            animation: msg-enter 0.15s ease-out;
          }

          @media (max-width: 640px) {
            .container { padding: var(--sp-2); }
            .message { max-width: none; }
          }
        </style>
        <script>
          (function() {
            var t = localStorage.getItem('hangout_theme') || 'dark';
            document.documentElement.setAttribute('data-theme', t);
          })();
        </script>
      </head>
      <body>
        {@inner_content}
        <div id="connection-status" role="alert">Reconnecting...</div>
      </body>
    </html>
    """
  end
end
