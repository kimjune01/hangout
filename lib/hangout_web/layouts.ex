defmodule HangoutWeb.Layouts do
  use HangoutWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Hangout</title>
        <script defer phx-track-static src="/assets/app.js"></script>
        <style>
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; background: #0d1117; color: #c9d1d9; min-height: 100vh; }
          .container { max-width: 960px; margin: 0 auto; padding: 1rem; }
          .room-layout { display: flex; height: calc(100vh - 2rem); gap: 1rem; }
          .messages-panel { flex: 1; display: flex; flex-direction: column; min-width: 0; }
          .messages { flex: 1; overflow-y: auto; padding: 0.5rem; background: #161b22; border-radius: 6px; border: 1px solid #30363d; }
          .message { padding: 2px 0; line-height: 1.4; font-size: 0.9rem; }
          .message .nick { font-weight: bold; color: #58a6ff; }
          .message .time { color: #484f58; font-size: 0.8rem; margin-right: 0.5rem; }
          .message.system { color: #8b949e; font-style: italic; }
          .message.action { color: #d2a8ff; }
          .message.notice { color: #6b5714; }
          .sidebar { width: 200px; background: #161b22; border-radius: 6px; border: 1px solid #30363d; padding: 0.75rem; overflow-y: auto; flex-shrink: 0; }
          .sidebar h3 { font-size: 0.8rem; color: #8b949e; margin-bottom: 0.5rem; text-transform: uppercase; }
          .sidebar .nick-entry { padding: 2px 0; font-size: 0.85rem; display: flex; align-items: center; gap: 0.25rem; }
          .sidebar .nick-entry .bot-badge { font-size: 0.7rem; color: #8b949e; }
          .sidebar .nick-entry .op-badge { color: #f0883e; }
          .input-bar { display: flex; gap: 0.5rem; padding: 0.5rem 0; }
          .input-bar input { flex: 1; background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.5rem; border-radius: 4px; font-size: 0.9rem; }
          .input-bar button { background: #238636; color: #fff; border: none; padding: 0.5rem 1rem; border-radius: 4px; cursor: pointer; }
          .input-bar button:hover { background: #2ea043; }
          .header { display: flex; justify-content: space-between; align-items: center; padding: 0.5rem 0; border-bottom: 1px solid #30363d; margin-bottom: 0.5rem; }
          .header h1 { font-size: 1.1rem; color: #f0f6fc; }
          .header .badges { display: flex; gap: 0.5rem; align-items: center; font-size: 0.8rem; color: #8b949e; }
          .header .lock-badge { color: #f0883e; }
          .header .ttl-badge { color: #58a6ff; }
          .mod-controls { display: flex; gap: 0.25rem; margin-top: 0.5rem; }
          .mod-controls button { background: #21262d; color: #c9d1d9; border: 1px solid #30363d; padding: 0.25rem 0.5rem; border-radius: 4px; font-size: 0.75rem; cursor: pointer; }
          .mod-controls button:hover { background: #30363d; }
          .mod-controls button.danger { border-color: #f85149; color: #f85149; }
          .nick-prompt { text-align: center; padding: 4rem 1rem; }
          .nick-prompt input { background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.75rem; border-radius: 4px; font-size: 1rem; width: 16rem; }
          .nick-prompt button { background: #238636; color: #fff; border: none; padding: 0.75rem 1.5rem; border-radius: 4px; cursor: pointer; margin-top: 1rem; font-size: 1rem; display: block; margin: 1rem auto 0; }
          .social-contract { font-size: 0.75rem; color: #484f58; text-align: center; margin-top: 1rem; max-width: 24rem; margin-left: auto; margin-right: auto; line-height: 1.4; }
          .home-form { max-width: 24rem; margin: 4rem auto; text-align: center; }
          .home-form input { background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.75rem; border-radius: 4px; font-size: 1rem; width: 100%; margin-bottom: 0.75rem; }
          .home-form select { background: #0d1117; border: 1px solid #30363d; color: #c9d1d9; padding: 0.75rem; border-radius: 4px; font-size: 1rem; width: 100%; margin-bottom: 0.75rem; }
          .home-form button { background: #238636; color: #fff; border: none; padding: 0.75rem 2rem; border-radius: 4px; cursor: pointer; font-size: 1rem; }
          .kick-btn { background: none; border: none; color: #f85149; cursor: pointer; font-size: 0.7rem; margin-left: auto; padding: 0 4px; }
          .mobile-member-toggle { display: none; background: #161b22; border: 1px solid #30363d; color: #8b949e; padding: 0.25rem 0.75rem; border-radius: 4px; font-size: 0.8rem; cursor: pointer; }
          @media (max-width: 640px) {
            .sidebar { display: none; }
            .sidebar.mobile-open { display: block; width: 100%; }
            .room-layout { flex-direction: column; }
            .mobile-member-toggle { display: inline-block; }
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
