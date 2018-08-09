defmodule G.Master do
  use GenServer
  require Logger

  @master_atom :g_master

  # Assuming we have M expected shards and N clusters, a balanced group would
  # have exactly (M / N) shards / cluster. Obviously this isn't possible for a
  # lot of reasons (ex. 50 shards but 4 clusters expectes 12.5 shards per
  # cluster), so we give it a "threshold" - if all cluster are within
  # @balance_threshold of the perfect (M / N) count, the group is considered
  # balanaced.
  @balance_threshold 1

  def start_link(opts) do
    GenServer.start_link __MODULE__, opts
  end

  def init(_opts) do
    Logger.info "[MASTER] Starting master..."
    id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
    Logger.info "[MASTER] Master id: #{id}"
    state = %{
      id: id,
      last_shard_connect: -1,
      unused_shards: Enum.to_list(0..7),
      used_shards: [],
    }
    Process.send_after self(), :up, 1000
    {:ok, state}
  end

  def handle_info(:up, state) do
    Logger.info "[MASTER] Master node up!"
    Logger.info "[MASTER] Current state: #{inspect state, pretty: true}"
    Process.send_after self(), :get_clusters, 1000
    {:noreply, state}
  end

  def handle_info(:get_clusters, state) do
    ids = Swarm.multi_call :g_cluster, :get_shard_ids
    taken = Enum.reduce(ids, [], fn({cluster, shards}, acc) ->
              Logger.info "[MASTER] Connected cluster #{cluster} with shards: #{inspect shards, pretty: true}"
              acc ++ shards
            end)
    Logger.info "[MASTER] Used shards: #{inspect taken, pretty: true}"
    unused_shards = state[:unused_shards] -- taken
    Process.send_after self(), :start_sharding, 1500
    {:noreply, %{state | used_shards: taken, unused_shards: unused_shards}}
  end

  # Get clusters sorted by shard count. Clusters are sorted ascending, ie the
  # head of the list is smallest and the tail is the largest
  defp get_clusters_by_shard_count do
    # [{name, pid}]
    clusters = Swarm.registered()
    # This:
    # - Gets all pids in the swarm that are shard clusters
    # - Queries them for shard count
    # - Sorts them by shard count, ascending
    # - Picks the head of the list (ie. the cluster with the fewest shards on it)
    clusters
    |> Enum.filter(fn {cluster_module_name, _pid} ->
        cl_name = case cluster_module_name do
                    {_module, atom} ->
                      Atom.to_string atom
                    atom when is_atom(atom) ->
                      Atom.to_string atom
                    _ ->
                      raise ""
                  end
        String.starts_with? cl_name, "g_cluster"
      end)
    |> Enum.map(fn {name, cluster} ->
        shard_count = GenServer.call({:via, :swarm, name}, :get_shard_count)
        {shard_count, cluster, name}
      end)
    |> Enum.sort(fn {shard_count_1, _, _}, {shard_count_2, _, _} ->
        shard_count_1 < shard_count_2
      end)
  end

  def handle_info(:start_sharding, state) do
    unless length(state[:unused_shards]) == 0 do
      next_id = hd state[:unused_shards]

      {shard_count, target, name} = get_clusters_by_shard_count() |> hd
      # Once we have a target cluster, we can ask it to spawn a shard
      target_id = GenServer.call({:via, :swarm, name}, :get_id)
      Logger.info "[MASTER] Target cluster: #{target_id} (pid #{inspect target, pretty: true} @ #{inspect name, pretty: true}), #{shard_count} shards"
      GenServer.cast {:via, :swarm, name}, {:create_shard, {next_id, length(state[:used_shards]) + length(state[:unused_shards])}}
      {:noreply, state}
    else
      Logger.info "[MASTER] Finished booting shards!"
      # Once we finish booting shards, we can start processing unused IDs.
      send self(), :check_reconnect_queue
      send self(), :check_rebalance
      {:noreply, state}
    end
  end

  def handle_info(:check_reconnect_queue, state) do
    if length(state[:unused_shards]) > 0 do
      Logger.info "[MASTER] Reconnecting shards: #{inspect state[:unused_shards], pretty: true}"
      send self(), :start_sharding
    else
      Process.send_after self(), :check_reconnect_queue, 5000
    end
    {:noreply, state}
  end

  def handle_info(:check_rebalance, state) do
    # {shard_count, target, name}
    sorted_clusters = get_clusters_by_shard_count()
                      |> Enum.sort(fn {shard_count_1, _, _}, {shard_count_2, _, _} ->
                        shard_count_1 < shard_count_2
                      end)
    shard_count = length(state[:used_shards]) + length(state[:unused_shards])
    expected_count = round(shard_count / length(sorted_clusters))
    Logger.debug "[MASTER] #{length(sorted_clusters)} clusters, #{shard_count} shards, #{expected_count} expected"

    reduce =
      sorted_clusters
      |> Enum.filter(fn({shards, _target, _name}) ->
          above_threshold shards, expected_count
        end)

    if length(reduce) > 0 do
      # We have clusters that need to reduce
      reduce
      |> Enum.each(fn({shards, _target, name}) ->
        target_id = GenServer.call {:via, :swarm, name}, :get_id
        reduction = reduce_to_threshold shards, expected_count
        if reduction > 0 do
          # We're above the threshold, tell it to kill shards to bring it back down
          Logger.warn "[MASTER] Asking cluster #{target_id} to stop #{reduction} shards to bring itself under threshold."
          GenServer.cast {:via, :swarm, name}, {:stop_shards, reduction}
        end
      end)
    else
      # Recheck later
      Process.send_after self(), :check_rebalance, 1000
    end

    {:noreply, state}
  end
  defp within_threshold(count, expected) when is_integer(count) and is_integer(expected) do
    count >= expected - @balance_threshold and count <= expected + @balance_threshold
  end
  defp above_threshold(count, expected) when is_integer(count) and is_integer(expected) do
    count >= expected + @balance_threshold
  end
  defp reduce_to_threshold(count, expected) when is_integer(count) and is_integer(expected) do
    count - (expected + @balance_threshold)
  end

  def handle_cast({:shard_booted, shard_id}, state) do
    Logger.info "[MASTER] Booted shard #{shard_id}"
    unused_shards = state[:unused_shards] |> List.delete(shard_id)
    used_shards = state[:used_shards] ++ [shard_id]
    Process.send_after self(), :start_sharding, 500
    {:noreply, %{state | unused_shards: unused_shards, used_shards: used_shards}}
  end
  def handle_cast({:shard_resumed, shard_id}, state) do
    Logger.info "[MASTER] Resumed shard #{shard_id}"
    unused_shards = state[:unused_shards] |> List.delete(shard_id)
    used_shards = state[:used_shards] ++ [shard_id]
    send self(), :start_sharding
    {:noreply, %{state | unused_shards: unused_shards, used_shards: used_shards}}
  end

  def handle_cast({:shard_down, shard_id}, state) do
    Logger.warn "[MASTER] Shard #{shard_id} down, queueing reconnect"
    used_shards = state[:used_shards] |> List.delete(shard_id) |> Enum.uniq
    unused_shards = (state[:unused_shards] ++ [shard_id]) |> Enum.uniq
    {:noreply, %{state | unused_shards: unused_shards, used_shards: used_shards}}
  end

  def handle_call(:get_master_id, _from, state) do
    {:reply, state[:id], state}
  end

  #####################
  ## Swarm callbacks ##
  #####################

  def handle_call({:swarm, :begin_handoff}, _from, state) do
    {:reply, {:resume, state}, state}
  end

  def handle_cast({:swarm, :end_handoff, handoff_state}, state) do
    new_state = handoff_state
                |> Map.put(:id, state[:id])
    Swarm.publish :g_cluster, {:new_master, new_state[:id]}
    {:noreply, new_state}
  end

  def handle_cast({:swarm, :resolve_conflict, _external_state}, state) do
    {:noreply, state}
  end

  def handle_info({:swarm, :die}, state) do
    {:stop, :shutdown, state}
  end

  def get_master_id do
    GenServer.call {:via, :swarm, @master_atom}, :get_master_id
  end
end
