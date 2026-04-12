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
        <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='80' fill='%237cc7b2'>#</text></svg>" />
        <script defer phx-track-static src="/assets/app.js"></script>
        <style>
          :root {
            --bg: #11100f;
            --panel: #191816;
            --panel-2: #211f1c;
            --border: #3a3630;
            --text: #e3ded7;
            --muted: #9c948a;
            --dim: #6e7681;
            --accent: #7cc7b2;
            --accent-2: #e0b15d;
            --danger: #ff6b63;
            --success: #7cc7b2;
            --font-ui: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            --font-mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
          }

          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

          body {
            font-family: var(--font-ui);
            background: var(--bg);
            color: var(--text);
            min-height: 100vh;
            font-size: 16px;
            line-height: 1.5;
          }

          /* --- Layout --- */
          .container { max-width: 960px; margin: 0 auto; padding: 0.5rem 1rem; height: 100vh; display: flex; flex-direction: column; }
          .room-layout { display: flex; flex: 1; gap: 1rem; min-height: 0; }
          .messages-panel { flex: 1; display: flex; flex-direction: column; min-width: 0; }

          /* --- Messages --- */
          .messages {
            flex: 1;
            overflow-y: auto;
            padding: 0.75rem 1rem;
            background: var(--panel);
            border-radius: 6px;
            border: 1px solid var(--border);
          }
          .message { padding: 3px 0; line-height: 1.5; font-size: 1rem; max-width: 78ch; }
          .message .nick { font-family: var(--font-mono); font-weight: 600; font-size: 0.9375rem; }
          .message .time { font-family: var(--font-mono); color: var(--dim); font-size: 0.8125rem; margin-right: 0.5rem; }
          .message.system {
            color: var(--muted);
            font-style: normal;
            border-left: 2px solid var(--border);
            padding-left: 0.5rem;
            font-size: 0.9375rem;
          }
          .message.action { color: var(--accent); }
          .message.notice { color: var(--accent-2); }

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
          .copy-md {
            background: none;
            border: none;
            color: var(--dim);
            font-family: var(--font-mono);
            font-size: 0.6875rem;
            cursor: pointer;
            padding: 0 0.25rem;
            vertical-align: top;
            opacity: 0;
            transition: opacity 0.15s;
          }
          .message:hover .copy-md { opacity: 1; }
          .copy-md:hover { color: var(--accent); }

          /* --- Member toggle + drawer (inside messages panel) --- */
          .member-toggle {
            position: absolute;
            top: 0.5rem;
            right: 0.5rem;
            background: var(--panel-2);
            border: 1px solid var(--border);
            color: var(--muted);
            padding: 0.2rem 0.5rem;
            border-radius: 4px;
            font-size: 0.75rem;
            font-family: var(--font-mono);
            cursor: pointer;
            z-index: 5;
          }
          .member-toggle:hover { color: var(--text); }
          .member-drawer {
            position: absolute;
            top: 2rem;
            right: 0.5rem;
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 0.5rem 0.75rem;
            max-height: 50%;
            overflow-y: auto;
            z-index: 10;
            min-width: 140px;
          }
          .nick-entry { padding: 3px 0; font-size: 0.875rem; display: flex; align-items: center; gap: 0.25rem; }
          .nick-entry .bot-badge { font-size: 0.6875rem; color: var(--muted); font-family: var(--font-mono); }
          .nick-entry .op-badge { color: var(--accent-2); font-family: var(--font-mono); }

          /* --- Input bar --- */
          .input-bar { display: flex; align-items: center; gap: 0; padding: 0.5rem 0; padding-bottom: calc(0.5rem + env(safe-area-inset-bottom, 0px)); }
          .input-bar .nick-label {
            font-family: var(--font-mono);
            color: var(--muted);
            padding: 0.5rem 0;
            font-size: 0.875rem;
            white-space: nowrap;
            user-select: none;
          }
          .input-bar .nick-label::after { content: " >"; color: var(--dim); }
          .input-bar input {
            flex: 1;
            background: transparent;
            border: none;
            border-bottom: 1px solid var(--border);
            color: var(--text);
            padding: 0.5rem 0.5rem;
            font-size: 1rem;
            font-family: var(--font-ui);
            outline: none;
          }
          .input-bar input:focus { border-bottom-color: var(--accent); }
          .voice-btn {
            background: none;
            border: 1px solid var(--border);
            color: var(--dim);
            padding: 0.25rem 0.5rem;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.75rem;
            font-family: var(--font-mono);
            margin-right: 0.25rem;
          }
          .voice-btn:hover { color: var(--text); border-color: var(--muted); }
          .voice-btn.voice-active { color: var(--accent); border-color: var(--accent); }
          .voice-btn.voice-speaking { box-shadow: 0 0 0 3px rgba(124, 199, 178, 0.4); }
          @keyframes voice-pulse { 0%, 100% { box-shadow: 0 0 0 2px rgba(124, 199, 178, 0.3); } 50% { box-shadow: 0 0 0 5px rgba(124, 199, 178, 0.5); } }
          .voice-btn.voice-speaking { animation: voice-pulse 0.6s ease-in-out infinite; }
          .input-bar input::placeholder { color: var(--dim); }
          .input-bar button {
            background: none;
            color: var(--dim);
            border: none;
            padding: 0.5rem 0.75rem;
            cursor: pointer;
            font-size: 0.875rem;
          }
          .input-bar button:hover { color: var(--accent); }

          /* --- Header --- */
          .header {
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            padding: 0.5rem 0;
            border-bottom: 1px solid var(--border);
            margin-bottom: 0.5rem;
          }
          .header h1 { font-family: var(--font-mono); font-size: 1.125rem; color: var(--text); font-weight: 600; }
          .header .topic { font-size: 0.875rem; color: var(--muted); margin-left: 1rem; font-weight: normal; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .header .badges { display: flex; gap: 0.5rem; align-items: center; font-size: 0.8125rem; color: var(--muted); flex-shrink: 0; }
          .header .lock-badge { color: var(--accent-2); }
          .header .ttl-badge { color: var(--accent); }
          .header .member-count { font-family: var(--font-mono); font-size: 0.8125rem; }

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
          }
          .mod-controls summary::before { content: "⚙ room controls"; }
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
            padding: 0.2rem 0.5rem;
            border-radius: 4px;
            font-size: 0.75rem;
            cursor: pointer;
          }
          .mod-controls button:hover { background: var(--border); color: var(--text); }
          .mod-controls button.danger { border-color: var(--danger); color: var(--danger); }
          .mod-controls button.danger:hover { background: var(--danger); color: var(--bg); }

          /* --- Nick prompt --- */
          .nick-prompt { text-align: center; padding: 6rem 1rem 4rem; }
          .nick-prompt .room-name {
            font-family: var(--font-mono);
            font-size: 2rem;
            color: var(--accent);
            font-weight: 600;
            margin-bottom: 0.5rem;
          }
          .nick-prompt .room-info { color: var(--muted); font-size: 0.9375rem; margin-bottom: 2rem; }
          .nick-prompt input {
            background: transparent;
            border: none;
            border-bottom: 2px solid var(--border);
            color: var(--text);
            padding: 0.75rem 0.5rem;
            font-size: 1.125rem;
            width: 16rem;
            text-align: center;
            font-family: var(--font-mono);
            outline: none;
          }
          .nick-prompt input:focus { border-bottom-color: var(--accent); }
          .nick-prompt input::placeholder { color: var(--dim); }
          .nick-prompt button {
            background: var(--accent);
            color: var(--bg);
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
          .social-contract {
            font-size: 0.8125rem;
            color: var(--dim);
            text-align: center;
            margin-top: 2rem;
            max-width: 28rem;
            margin-left: auto;
            margin-right: auto;
            line-height: 1.5;
          }
          .social-contract p + p { margin-top: 0.25rem; }

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
            color: var(--bg);
            border: none;
            padding: 0.6rem 2rem;
            border-radius: 4px;
            cursor: pointer;
            font-size: 1rem;
            font-weight: 600;
          }
          .home-form button:hover { opacity: 0.9; }

          /* --- Flash messages --- */
          .flash { padding: 0.5rem 0.75rem; border-radius: 4px; font-size: 0.875rem; margin-bottom: 0.5rem; }
          .flash.error { background: rgba(255, 107, 99, 0.1); border: 1px solid var(--danger); color: var(--danger); }
          .flash.info { background: rgba(124, 199, 178, 0.1); border: 1px solid var(--accent); color: var(--accent); }

          /* --- Kick button --- */
          .kick-btn { background: none; border: none; color: var(--danger); cursor: pointer; font-size: 0.6875rem; margin-left: auto; padding: 0 4px; opacity: 0.5; }
          .kick-btn:hover { opacity: 1; }

          /* --- Mod link --- */
          .mod-link-banner {
            background: var(--panel-2);
            padding: 0.5rem 0.75rem;
            border-radius: 4px;
            margin-bottom: 0.5rem;
            font-size: 0.8125rem;
          }
          .mod-link-banner .label { color: var(--accent-2); }
          .mod-link-banner code { font-family: var(--font-mono); color: var(--accent); word-break: break-all; font-size: 0.75rem; }

          /* --- Room ended state --- */
          .room-ended { text-align: center; padding: 6rem 1rem; }
          .room-ended h2 { font-family: var(--font-mono); color: var(--muted); margin-bottom: 1rem; }
          .room-ended a { color: var(--accent); }

          @media (max-width: 640px) {
            .container { padding: 0.5rem; }
            .message { max-width: none; }
          }
        </style>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
