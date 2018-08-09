defmodule G.Cluster do
  use GenServer
  require Logger

  @master_atom :g_master
  @master_poll_wait 100

  def start_link(opts) do
    GenServer.start_link __MODULE__, opts, name: __MODULE__
  end

  def init(opts) do
    state = %{
      ready: false,
      id: opts[:id],
      refs: %{},
      pids: %{},
      shard_count: 0,
    }
    Process.register self(), G.Cluster
    Logger.info "[CLUSTER] Started as #{state[:id]}"
    Process.send_after self(), :block_until_master, @master_poll_wait
    {:ok, state}
  end

  def handle_call(:get_id, _from, state) do
    {:reply, state[:id], state}
  end

  def handle_call(:get_shard_count, _from, state) do
    {:reply, state[:shard_count], state}
  end

  def handle_call(:get_shard_ids, _from, state) do
    {:reply, {state[:id], Map.values(state[:refs])}, state}
  end

  # This is done synchronously so that the caller (SIGTERM handler) can be sure
  # that we've actually finished stopping shards before shutting down.
  def handle_call(:stop_all_shards, _from, state) do
    # Leave the group
    Swarm.leave :g_cluster, self()
    # Unregister from the swarm
    Swarm.unregister_name :"g_cluster_#{state[:id]}"
    # Alert the master that ALL our shards just went down
    ids = state[:refs] |> Map.values |> Enum.uniq
    for id <- ids do
      # Stop the process and alert master
      Process.exit state[:pids][id], :kill # lol
      GenServer.cast {:via, :swarm, @master_atom}, {:shard_down, id}
    end
    {:reply, nil, state}
  end

  def handle_cast({:create_shard, {shard_id, shard_count}}, state) do
    shard_state = %{
      shard_id: shard_id,
      shard_count: shard_count,
      cluster: self(),
      token: System.get_env("BOT_TOKEN"),
    }
    {res, pid} = G.Shard.start_link shard_state
    if res == :ok do
      ref = Process.monitor pid
      refs = state[:refs] |> Map.put(ref, shard_id)
      pids = state[:pids] |> Map.put(shard_id, pid)
      {:noreply, %{state | refs: refs, pids: pids, shard_count: state[:shard_count] + 1}}
    else
      Logger.warn "[CLUSTER] Couldn't start shard #{shard_id}/#{shard_count}!?"
      {:noreply, state}
    end
  end

  def handle_cast({:stop_shards, count}, state) do
    # Just take however many shards off the top and stop them
    state[:pids]
      |> Map.keys
      |> Enum.take(count)
      |> Enum.each(fn(id) ->
          # Tell each shard to close its connection
          send state[:pids][id], :close_connection
        end)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Alert master that shard went rip
    shard_id = state[:refs][ref]
    {_, refs} = state[:refs] |> Map.pop(ref)
    {_, pids} = state[:pids] |> Map.pop(shard_id)
    Logger.warn "[CLUSTER] Shard #{shard_id} down: #{inspect reason, pretty: true}"
    GenServer.cast {:via, :swarm, @master_atom}, {:shard_down, shard_id}
    {:noreply, %{state | shard_count: state[:shard_count] - 1, refs: refs, pids: pids}}
  end

  def handle_info({:shard_booted, shard_id}, state) do
    GenServer.cast {:via, :swarm, @master_atom}, {:shard_booted, shard_id}
    {:noreply, state}
  end
  def handle_info({:shard_resumed, shard_id}, state) do
    GenServer.cast {:via, :swarm, @master_atom}, {:shard_resumed, shard_id}
    {:noreply, state}
  end

  def handle_info(:block_until_master, state) do
    unless Swarm.whereis_name(@master_atom) == :undefined do
      Logger.info "[CLUSTER] Master found!"
      state = state |> Map.put(:ready, true)
      send self(), :master_found
      {:noreply, state}
    else
      Process.send_after self(), :block_until_master, @master_poll_wait
      {:noreply, state}
    end
  end

  def handle_info(:master_found, state) do
    master = G.Master.get_master_id()
    Logger.info "[CLUSTER] Connected to master: #{master}"
    {:noreply, state}
  end
end
