defmodule G.Master do
  use GenServer
  require Logger

  @master_atom :g_master

  def start_link(opts) do
    GenServer.start_link __MODULE__, opts
  end

  def init(opts) do
    Logger.info "[MASTER] Starting master..."
    id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
    Logger.info "[MASTER] Master id: #{id}"
    state = %{
      id: id,
      last_shard_connect: -1,
    }
    Process.send_after self(), :up, 1000
    {:ok, state}
  end

  def handle_call(:get_master_id, _from, state) do
    {:reply, state[:id], state}
  end

  # called when a handoff has been initiated due to changes
  # in cluster topology, valid response values are:
  #
  #   - `:restart`, to simply restart the process on the new node
  #   - `{:resume, state}`, to hand off some state to the new process
  #   - `:ignore`, to leave the process running on its current node
  #
  def handle_call({:swarm, :begin_handoff}, _from, state) do
    {:reply, {:resume, state}, state}
  end

  # called after the process has been restarted on its new node,
  # and the old process' state is being handed off. This is only
  # sent if the return to `begin_handoff` was `{:resume, state}`.
  # **NOTE**: This is called *after* the process is successfully started,
  # so make sure to design your processes around this caveat if you
  # wish to hand off state like this.
  def handle_cast({:swarm, :end_handoff, handoff_state}, state) do
    new_state = handoff_state
                |> Map.put(:id, state[:id])
    Swarm.publish :g_cluster, {:new_master, new_state[:id]}
    {:noreply, new_state}
  end

  # called when a network split is healed and the local process
  # should continue running, but a duplicate process on the other
  # side of the split is handing off its state to us. You can choose
  # to ignore the handoff state, or apply your own conflict resolution
  # strategy
  def handle_cast({:swarm, :resolve_conflict, _external_state}, state) do
    {:noreply, state}
  end

  # this message is sent when this process should die
  # because it is being moved, use this as an opportunity
  # to clean up
  def handle_info({:swarm, :die}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info(:up, state) do
    Logger.info "Master node up!"
    Process.send_after self(), :get_clusters, 5000
    #Logger.info "Token: #{state[:token]}"
    #Logger.info "I am: #{inspect self(), pretty: true}"
    #Logger.info "Registered pids:"
    #members = Swarm.members(:g)
    #Swarm.registered()
    #|> Enum.filter(fn {_, pid} -> Enum.member?(members, pid) end)
    #|> Enum.each(fn {name, pid} -> Logger.info "- #{inspect name, pretty: true} -> #{inspect pid, pretty: true}" end)
    #fake = Swarm.whereis_name(:asdf)
    #Logger.info "This won't exist: #{inspect fake, pretty: true}"
    {:noreply, state}
  end

  def handle_info(:get_clusters, state) do
    ids = Swarm.multi_call :g_cluster, :get_id
    Enum.each ids, fn id ->
        Logger.info "[MASTER] Connected cluster: #{id}"
      end
    {:noreply, state}
  end

  def handle_info(:start_sharding, state) do
    # Get all clusters
    clusters = Swarm.members :g_cluster
    # Sort by shard count
    # iex(1)> shards = [{1, nil}, {0, nil}, {5, nil}, {0, nil}]
    # [{1, nil}, {0, nil}, {5, nil}, {0, nil}]
    # iex(2)> shards |> Enum.sort(fn {c1, _}, {c2, _} -> c1 < c2 end)
    # [{0, nil}, {0, nil}, {1, nil}, {5, nil}]
    # iex(3)>
    {shard_count, target} = clusters
                            |> Enum.map(fn cluster ->
                                shard_count = GenServer.call({:via, :swarm, cluster}, :get_shard_count)
                                {shard_count, cluster}
                              end)
                            |> Enum.sort(fn {shard_count_1, _cluster_1}, {shard_count_2, _cluster_2} ->
                                shard_count_1 < shard_count_2
                              end)
    target_id = GenServer.call({:via, :swarm, target}, :get_id)
    Logger.info "[MASTER] Target cluster: #{target_id} (pid #{inspect target, pretty: true}), #{shard_count} shards"
    # TODO: Proper shard ID assignment
    GenServer.cast {:via, :swarm, target}, {:create_shard, {0, 1}}
    {:noreply, state}
  end

  def get_master_id do
    GenServer.call {:via, :swarm, @master_atom}, :get_master_id
  end
end
