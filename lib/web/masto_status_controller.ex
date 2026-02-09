if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Posts.Web.MastoStatusController do
    @moduledoc "Mastodon-compatible status creation endpoint"

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Posts.API.MastoAdapter

    def create(conn, params), do: MastoAdapter.create_status(params, conn)
  end
end
