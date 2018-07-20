defmodule G.Supervisor do
  use Supervisor
  require Logger

  def start_link(_) do
    Supervisor.start_link __MODULE__, [], name: __MODULE__
  end

  @impl true
  def init(_arg) do
    Supervisor.init [], strategy: :one_for_one
  end

  def register(name, opts) do
    #spec = {name, opts}
    id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
    spec = %{
      id: :"g_swarm_worker_#{id}",
      start: {name, :start_link, [opts]}
    }
    Logger.info "[GSUP] Registering child with spec #{inspect spec, pretty: true}"
    {:ok, _pid} = Supervisor.start_child __MODULE__, spec
  end
end
