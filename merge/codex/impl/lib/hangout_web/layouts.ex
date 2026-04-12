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
        <script defer type="text/javascript" src="/assets/js/app.js"></script>
        <style>
          body { margin: 0; font-family: system-ui, sans-serif; background: #f7f7f5; color: #1e2422; }
          a { color: #0a6f6a; }
          .page { min-height: 100vh; display: flex; flex-direction: column; }
          .home, .room { width: min(1100px, calc(100% - 24px)); margin: 0 auto; }
          .home { padding: 64px 0; }
          .room { height: 100vh; display: grid; grid-template-rows: auto 1fr auto; }
          .bar { display: flex; gap: 12px; align-items: center; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid #d6d8d2; }
          .chat { display: grid; grid-template-columns: 1fr 220px; min-height: 0; }
          .messages { overflow-y: auto; padding: 16px 12px 16px 0; }
          .members { border-left: 1px solid #d6d8d2; padding: 16px; overflow-y: auto; }
          .composer { display: grid; grid-template-columns: 170px 1fr auto; gap: 8px; padding: 12px 0; border-top: 1px solid #d6d8d2; }
          input, select, button { font: inherit; border: 1px solid #aeb4ad; border-radius: 6px; padding: 9px 10px; background: white; }
          button { background: #123d38; color: white; border-color: #123d38; cursor: pointer; }
          button.secondary { background: white; color: #1e2422; }
          button.danger { background: #8b1e24; border-color: #8b1e24; }
          .msg { margin: 0 0 10px; line-height: 1.35; overflow-wrap: anywhere; }
          .meta { color: #66706a; font-size: 13px; }
          .notice { color: #6b5714; }
          .contract { max-width: 700px; line-height: 1.5; color: #4b5450; }
          .controls { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
          @media (max-width: 760px) {
            .chat { grid-template-columns: 1fr; }
            .members { border-left: 0; border-top: 1px solid #d6d8d2; max-height: 120px; }
            .composer { grid-template-columns: 1fr; }
          }
        </style>
      </head>
      <body>
        <div class="page">
          {@inner_content}
        </div>
      </body>
    </html>
    """
  end
end
