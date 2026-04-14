defmodule HangoutWeb.InfoModal do
  use Phoenix.Component

  attr :legal_url, :string, default: nil
  attr :agent_token_url, :string, default: nil
  attr :agent_connected?, :boolean, default: false
  attr :nick, :string, default: nil

  def info_modal(assigns) do
    ~H"""
    <div class="info-backdrop" phx-click="close_info"></div>
    <div class="info-modal" phx-window-keydown="close_info" phx-key="Escape">
      <h3>About this room</h3>
      <ul>
        <li>
          🔒 The room disappears when everyone leaves. No history is saved.
        </li>
        <li>
          🔑 Your identity is a key stored in this browser.
          <div class="hint">To use your nick on another device, export it below and import there.</div>
        </li>
        <li>
          <button onclick="var kp=localStorage.getItem('hangout_keypair');if(kp){var b=new Blob([kp],{type:'application/json'});var a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='hangout-identity.json';a.click()}">Export identity</button>
          — save your key to a file
        </li>
        <li>
          <button onclick="var i=document.createElement('input');i.type='file';i.accept='.json';i.onchange=function(){var r=new FileReader();r.onload=function(){try{var p=JSON.parse(r.result);localStorage.setItem('hangout_keypair',JSON.stringify(p));window.location.reload()}catch(e){alert('Invalid identity file')}};r.readAsText(i.files[0])};i.click()">Import identity</button>
          — load a key from another device
        </li>
        <li>
          <button onclick="if(confirm('This will forget your nick and generate a new identity. Continue?')){localStorage.removeItem('hangout_keypair');localStorage.removeItem('hangout_nick');window.location.reload()}">Abandon nick &amp; start over</button>
          <div class="hint">Generates a new identity. Your old nick becomes available for anyone.</div>
        </li>
        <%= if @nick do %>
          <li>
            <button phx-click="generate_agent_token">Invite your agent</button>
            <%= if @agent_token_url do %>
              <div class="agent-invite-actions">
                <button onclick={"navigator.clipboard.writeText(#{Jason.encode!(@agent_token_url)}).then(() => { this.textContent='✓ copied'; setTimeout(() => this.textContent='Copy agent URL', 2000) })"}>Copy agent URL</button>
              </div>
            <% end %>
            <div class="hint">
              Your agent will see room messages and respond from your working directory. Don't connect from directories with secrets you wouldn't share.
            </div>
            <%= if @agent_token_url do %>
              <div class="hint">
                <%= if @agent_connected? do %>
                  🟢 agent connected
                <% else %>
                  ⚪ waiting for agent to connect…
                <% end %>
              </div>
              <div class="agent-invite-actions">
                <button phx-click="revoke_agent_token">Disconnect agent</button>
              </div>
            <% end %>
          </li>
        <% end %>
        <%= if @legal_url do %>
          <li>
            <a href={@legal_url} target="_blank">Terms &amp; privacy</a>
          </li>
        <% end %>
        <li>
          <a href="https://github.com/kimjune01/hangout" target="_blank">Source code</a>
          <span style="color: var(--dim);">— AGPL-3.0</span>
        </li>
        <li>
          <a href="https://june.kim/chat-june-kim" target="_blank">Why I built this</a>
        </li>
      </ul>
    </div>
    """
  end
end
