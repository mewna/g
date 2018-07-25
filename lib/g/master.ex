defmodule G.Master do
  use GenServer
  require Logger

  @master_atom :g_master

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
      unused_shards: Enum.to_list(0..3),
      used_shards: [],
    }
    Process.send_after self(), :up, 1000
    {:ok, state}
  end

  def handle_info(:up, state) do
    Logger.info "[MASTER] Master node up!"
    Process.send_after self(), :get_clusters, 1000
    {:noreply, state}
  end

  def handle_info(:get_clusters, state) do
    ids = Swarm.multi_call :g_cluster, :get_id
    Enum.each ids, fn id ->
        Logger.info "[MASTER] Connected cluster: #{id}"
      end
    Process.send_after self(), :start_sharding, 1500
    {:noreply, state}
  end

  def handle_info(:start_sharding, state) do
    unless length(state[:unused_shards]) == 0 do
      next_id = hd state[:unused_shards]
      # Get all clusters
      #clusters = Swarm.members :g_cluster
      # [{name, pid}]
      clusters = Swarm.registered()

      # This:
      # - Gets all pids in the swarm that are shard clusters
      # - Queries them for shard count
      # - Sorts them by shard count, ascending
      # - Picks the head of the list (ie. the cluster with the fewest shards on it)
      {shard_count, target, name} = clusters
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
                                    |> hd
      target_id = GenServer.call({:via, :swarm, name}, :get_id)
      Logger.info "[MASTER] Target cluster: #{target_id} (pid #{inspect target, pretty: true} @ #{inspect name, pretty: true}), #{shard_count} shards"
      GenServer.cast {:via, :swarm, name}, {:create_shard, {next_id, length(state[:used_shards]) + length(state[:unused_shards])}}
      {:noreply, state}
    else
      Logger.info "[MASTER] Finished booting shards!"
      {:noreply, state}
    end
  end

  def handle_cast({:shard_booted, shard_id}, state) do
    Logger.info "[MASTER] Booted shard #{shard_id}"
    unused_shards = state[:unused_shards] |> List.delete(shard_id)
    used_shards = state[:used_shards] ++ [shard_id]
    Process.send_after self(), :start_sharding, 500
    {:noreply, %{state | unused_shards: unused_shards, used_shards: used_shards}}
  end

  def handle_cast({:shard_down, shard_id}, state) do
    Logger.info "[MASTER] Shard #{shard_id} down, queueing reconnect"
    used_shards = state[:used_shards] |> List.delete(shard_id)
    unused_shards = state[:unused_shards] ++ [shard_id]
    {:noreply, %{state | unused_shards: unused_shards, used_shards: used_shards}}
  end

  def handle_call(:get_master_id, _from, state) do
    {:reply, state[:id], state}
  end

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
