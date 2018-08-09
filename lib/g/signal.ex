defmodule G.Signal do
  require Logger

  @behaviour :gen_event

  def swap_handlers do
    :os.set_signal(:sigterm, :handle)
    # Added for my sanity - probably not needed
    :os.set_signal(:sighup, :handle)
    :os.set_signal(:sigquit, :handle)
    :os.set_signal(:sigabrt, :handle)
    :os.set_signal(:sigalrm, :handle)
    :os.set_signal(:sigusr1, :handle)
    :os.set_signal(:sigusr2, :handle)
    :os.set_signal(:sigchld, :handle)
    :os.set_signal(:sigstop, :handle)
    :os.set_signal(:sigtstp, :handle)
    # Actually swap the signal handlers
    :gen_event.swap_sup_handler(
      :erl_signal_server,
      {:erl_signal_handler, []},
      {G.Signal, []}
    )
  end

  def init(args) do
    Logger.info("[SIGNAL] Starting signal handler...")
    {:ok, args}
  end

  def handle_call(req, state) do
    Logger.warn("[SIGNAL] Unhandled call: #{inspect(req, pretty: true)}")
    {:ok, :ok, state}
  end

  def handle_event(:sigterm, state) do
    Logger.warn("[SIGNAL] Got SIGTERM")
    # Once we get SIGTERM, tell the cluster to stop all shards, then exit.
    GenServer.call G.Cluster, :stop_all_shards
    :init.stop()
    {:ok, state}
  end

  def handle_event(event, state) do
    Logger.warn("[SIGNAL] Unhandled event: #{inspect(event, pretty: true)}")
    {:ok, state}
  end

  def handle_info(msg, _state) do
    Logger.warn("[SIGNAL] Unhandled :info: #{inspect(msg, pretty: true)}")
  end

  def terminate(_, _) do
    Logger.warn("[SIGNAL] Signal handler terminating!")
  end
end
