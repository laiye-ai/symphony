defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            // Whether a message is actually clipped depends on the rendered
            // width, which the server cannot know, so the browser measures it
            // and the expand control is revealed only when there is something
            // hidden to reveal.
            //
            // The card is observed rather than measured once: at mount the pane
            // has not settled to its final width yet, and `updated` only fires
            // when LiveView patches this element, which never happens while the
            // message text stays the same. A single early measurement therefore
            // sticks, and a message that fits ends up offering to expand.
            function markClamped(el) {
              var card = el.closest(".trail-card");
              if (!card) return;
              card.classList.toggle("is-clamped", el.scrollHeight - el.clientHeight > 1);
            }

            var hooks = {
              Clamp: {
                mounted: function () {
                  var self = this;
                  markClamped(this.el);

                  var card = this.el.closest(".trail-card");

                  if (card && window.ResizeObserver) {
                    this.observer = new ResizeObserver(function () { markClamped(self.el); });
                    this.observer.observe(card);
                  }
                },
                updated: function () { markClamped(this.el); },
                destroyed: function () { if (this.observer) this.observer.disconnect(); }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
