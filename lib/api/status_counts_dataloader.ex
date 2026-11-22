if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Posts.API.StatusCountsDataloader do
    @moduledoc "Dataloader.KV source: posts per user and each user's newest post, batched per request in one query (`Posts.stats_for_users/1`)."

    @no_posts %{count: 0, newest_id: nil}

    def data, do: Dataloader.KV.new(&fetch/2)

    def fetch(:counts, user_ids) do
      user_ids = MapSet.to_list(user_ids)
      stats = Bonfire.Posts.stats_for_users(user_ids)

      Map.new(user_ids, &{&1, Map.get(stats, &1, @no_posts)})
    end

    def fetch(_batch, user_ids), do: Map.new(user_ids, &{&1, nil})

    @doc "Resolver for `statuses_count` on a user or a group, batched through the `:status_counts` source."
    def statuses_count(parent, _args, resolution),
      do: load(parent, resolution, 0, & &1.count)

    @doc "Resolver for `last_post_at` on a user or a group: the date of the newest post, nil without posts (masto-live-fixes decision 14). Same batch as `statuses_count`, so no extra query."
    def last_post_at(parent, _args, resolution) do
      load(parent, resolution, nil, fn
        %{newest_id: nil} -> nil
        %{newest_id: id} -> Bonfire.Common.DatesTimes.date_from_pointer(id)
      end)
    end

    defp load(parent, %{context: %{loader: loader}}, default, fun) do
      case Bonfire.Common.Types.uid(parent) do
        nil ->
          {:ok, default}

        id ->
          loader
          |> Dataloader.load(:status_counts, :counts, id)
          |> Absinthe.Resolution.Helpers.on_load(&loaded(&1, id, default, fun))
      end
    end

    defp loaded(loader, id, default, fun) do
      case Dataloader.get(loader, :status_counts, :counts, id) do
        %{} = stats -> {:ok, fun.(stats)}
        _ -> {:ok, default}
      end
    end
  end
end
