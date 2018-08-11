defmodule G.Server do
  use Ace.HTTP.Service, [port: 80, cleartext: true]
  @impl Raxx.Server

  @master_atom :g_master

  def handle_request(%{method: :GET, path: []}, _config) do
    response(:ok)
    |> set_header("content-type", "application/json")
    |> set_body(Jason.encode!(%{data: "yes"}))
  end

  def handle_request(%{method: :GET, path: ["status", "master"]}, _config) do
    data = GenServer.call {:via, :swarm, @master_atom}, :get_status
    response(:ok)
    |> set_header("content-type", "application/json")
    |> set_body(Jason.encode!(data))
  end
end
