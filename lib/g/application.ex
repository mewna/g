defmodule G.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  @master_atom :g_master

  use Application
  require Logger
  def start(_type, _args) do
    G.Signal.swap_handlers()
    # External API port
    server_port = if System.get_env("PORT") do
                    System.get_env("PORT") |> String.to_integer
                  else
                    80
                  end
    children = [
      # Clustering
      # This is only used for clustering so size doesn't matter
      {Lace.Redis, %{redis_ip: System.get_env("REDIS_HOST"), redis_port: 6379, pool_size: 2, redis_pass: System.get_env("REDIS_PASS")}},
      {Lace, %{name: System.get_env("NODE_NAME"), group: System.get_env("GROUP_NAME"), cookie: System.get_env("NODE_COOKIE")}},
      # Dynamic processes
      {G.Supervisor, []},
      # API
      {G.Server, [%{}, [port: server_port]]},
      # Message queueing
      %{
        id: :q_backend,
        start: {Q, :start_link, [%{
          name: :q_backend,
          queue: "discord:event",
          host: System.get_env("REDIS_HOST"),
          port: 6379,
          pass: System.get_env("REDIS_PASS"),
          event_handler: nil, # &MyModule.handle/1,
          poll: false,
        }]}
      },
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: G.MainSupervisor]
    ret = Supervisor.start_link children ++ G.Redis.get_workers(), opts

    spawn fn ->
        Process.sleep 100 + :rand.uniform(200)
        Logger.info "[APP] Starting cluster worker..."
        id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
        Logger.info "[APP] Worker: #{id}"
        {:ok, pid} = GenServer.start_link G.Cluster, %{token: System.get_env("BOT_TOKEN"), id: id}, name: {:via, :swarm, {G.Cluster, :"g_cluster_#{id}"}}
        Swarm.join :g_cluster, pid
      end

    spawn fn ->
        Logger.info "[APP] Asking swarm to add master..."
        try do
          {:ok, pid} = Swarm.register_name @master_atom, G.Supervisor, :register, [G.Master, %{}]
          Swarm.join :g_master, pid
        rescue
          _ ->
            master_pid = Swarm.whereis_name @master_atom
            Logger.warn "[APP] Master started on another node (pid #{inspect master_pid, pretty: true})"
        end
      end
    ret
  end
end
