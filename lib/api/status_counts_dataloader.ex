if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Posts.API.StatusCountsDataloader do
    @moduledoc "Dataloader.KV source: posts per user, batched per request (`Posts.count_for_users/1`)."

    def data, do: Dataloader.KV.new(&fetch/2)

    def fetch(:counts, user_ids) do
      user_ids = MapSet.to_list(user_ids)
      counts = Bonfire.Posts.count_for_users(user_ids)

      Map.new(user_ids, &{&1, Map.get(counts, &1, 0)})
    end

    def fetch(_batch, user_ids), do: Map.new(user_ids, &{&1, nil})

    @doc "Resolver for `statuses_count` on a user or a group, batched through the `:status_counts` source."
    def statuses_count(parent, _args, %{context: %{loader: loader}}) do
      case Bonfire.Common.Types.uid(parent) do
        nil ->
          {:ok, 0}

        id ->
          loader
          |> Dataloader.load(:status_counts, :counts, id)
          |> Absinthe.Resolution.Helpers.on_load(
            &{:ok, Dataloader.get(&1, :status_counts, :counts, id) || 0}
          )
      end
    end
  end
end
