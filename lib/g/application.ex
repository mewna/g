defmodule G.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  @master_atom :g_master

  use Application
  require Logger
  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: G.Worker.start_link(arg)
      # {G.Worker, arg},
      {Lace.Redis, %{redis_ip: System.get_env("REDIS_HOST"), redis_port: 6379, pool_size: 10, redis_pass: System.get_env("REDIS_PASS")}},
      {Lace, %{name: System.get_env("NODE_NAME"), group: System.get_env("GROUP_NAME"), cookie: System.get_env("NODE_COOKIE")}},
      #{G.Cluster, %{token: System.get_env("BOT_TOKEN")}},
      {G.Supervisor, []},
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: G.MainSupervisor]
    ret = Supervisor.start_link(children, opts)

    spawn fn ->
        Process.sleep 100 + :rand.uniform(200)
        Logger.info "[APP] Starting cluster worker..."
        id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
        Logger.info "[APP] Worker: #{id}"
        #{:ok, pid} = Swarm.register_name :"g_cluster_#{id}", G.Supervisor, :register, [G.Cluster, ]
        {:ok, pid} = GenServer.start_link G.Cluster, %{token: System.get_env("BOT_TOKEN"), id: id}, name: {:via, :swarm, {G.Cluster, :"g_cluster_#{id}"}}
        #Swarm.join :g, pid
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
