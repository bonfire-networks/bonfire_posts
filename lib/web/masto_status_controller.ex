if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Posts.Web.MastoStatusController do
    @moduledoc "Mastodon-compatible status creation endpoint"

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Posts.API.MastoAdapter

    plug :require_publish_scope when action in [:create]

    def create(conn, params), do: MastoAdapter.create_status(params, conn)

    defp require_publish_scope(conn, _opts) do
      Bonfire.OpenID.Plugs.Authorize.require_token_scope(conn, ["write:statuses", "write"])
    end
  end
end
