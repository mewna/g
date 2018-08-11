defmodule G.Redis do
  @pool_size 10

  def get_workers do
    for i <- 0..(@pool_size - 1) do
      args = [
        [
          host: System.get_env("REDIS_HOST"),
          port: 6379,
          pass: System.get_env("REDIS_PASS"),
        ],
        [
          name: :"redix_#{i}"
        ]
      ]
      Supervisor.child_spec({Redix, args}, id: {Redix, i})
    end
  end

  def q(command) do
    Redix.command :"redix_#{random_index()}", command
  end
  def q(worker, command) do
    Redix.command worker, command
  end

  def t(f) do
    worker = :"redix_#{random_index()}"
    q worker, ["MULTI"]
    f.(worker)
    q worker, ["EXEC"]
  end

  defp random_index do
    rem System.unique_integer([:positive]), @pool_size
  end
end
