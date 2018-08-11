defmodule G.Shard do
  use WebSockex
  require Logger
  alias G.Redis

  @api_base "https://discordapp.com/api/v6"

  @large_threshold 250
  @gateway_url "wss://gateway.discord.gg/?v=6&encoding=etf"

  @session_key_base "g:shard:session"
  @seq_key_base "g:shard:seqnum"

  # Time before a shard is considered zombied, in milliseconds.
  # 5 minutes is a pretty reasonable timeout imo.
  @zombie_threshold 300_000

  ##################
  ## Opcode stuff ##
  ##################

  @op_dispatch              0   # Recv.
  @op_heartbeat             1   # Send/Recv.
  @op_identify              2   # Send
  @op_status_update         3   # Send
  @op_voice_state_update    4   # Send
  @op_voice_server_ping     5   # Send
  @op_resume                6   # Send
  @op_reconnect             7   # Recv.
  @op_request_guild_members 8   # Send
  @op_invalid_session       9   # Recv.
  @op_hello                 10  # Recv.
  @op_heartbeat_ack         11  # Recv.

  # Lookup table for translation
  @opcodes %{
    @op_dispatch              => :dispatch,
    @op_heartbeat             => :heartbeat,
    @op_identify              => :identify,
    @op_status_update         => :status_update,
    @op_voice_state_update    => :voice_state_update,
    @op_voice_server_ping     => :voice_server_ping,
    @op_resume                => :resume,
    @op_reconnect             => :reconnect,
    @op_request_guild_members => :request_guild_members,
    @op_invalid_session       => :invalid_session,
    @op_hello                 => :hello,
    @op_heartbeat_ack         => :heartbeat_ack
  }

  #############
  ## UTILITY ##
  #############

  defp info(state, message) do
    Logger.info "[SHARD #{state[:shard_id]}/#{state[:shard_count]}] #{message}"
  end
  defp warn(state, message) do
    Logger.warn "[SHARD #{state[:shard_id]}/#{state[:shard_count]}] #{message}"
  end
  defp debug(state, message) do
    Logger.debug "[SHARD #{state[:shard_id]}/#{state[:shard_count]}] #{message}"
  end

  ###############
  ## WEBSOCKET ##
  ###############

  def start_link(state) do
    unless state[:shard_id] >= state[:shard_count] do
      state |> info("Connecting to gateway #{@gateway_url}")
      internal_id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
      state = state
              |> Map.put(:internal_id, internal_id)
              |> Map.put(:seq, 0)
              |> Map.put(:trace, [])
              |> Map.put(:last_event, 0)
      # TODO: This should actually use WebSockex.start_link/4
      WebSockex.start @gateway_url, __MODULE__, state, [async: true]
    else
      {:error, "invalid shard count: #{state[:shard_id]} >= #{state[:shard_count]}"}
    end
  end

  def init(state) do
    state |> info("init?")
    {:ok, state}
  end

  def handle_connect(conn, state) do
    state |> info("Connected to gateway")
    unless is_nil state[:session_id] do
      state |> info("We have a session; expect OP 10 -> OP 6.")
    end
    headers = Enum.into conn.resp_headers, %{}
    ray = headers["Cf-Ray"]
    server = headers[:Server]
    state |> info("Connected to #{server} ray #{ray}")
    new_state = state
                |> Map.put(:client_pid, self())
                |> Map.put(:cf_ray, ray)
                |> Map.put(:trace, nil)
    # We connected to the gateway successfully, we're logging in now
    {:ok, new_state}
  end

  def handle_frame({:binary, msg}, state) do
    payload = :erlang.binary_to_term(msg)
    # When we get a gateway op, it'll be of the same form always, which makes our lives easier
    #state |> info("Got gateway payload: #{inspect payload, pretty: true}")
    state = state |> Map.put(:seq, payload[:s] || state[:seq])
                  |> Map.put(:last_event, :os.system_time(:millisecond))
    {res, reply, new_state} = handle_op payload[:op], payload, state
    case res do
      :reply -> {:reply, reply, new_state}
      :noreply -> {:ok, new_state}
      # Just immediately die
      :terminate -> {:close, new_state}
    end
  end

  def handle_frame(msg, state) do
    state |> info("Got non-ETF gateway payload: #{inspect msg, pretty: true}")
    {:ok, state}
  end

  def handle_info(:close_connection, state) do
    state |> warn("Disconnecting due to request")
    {:close, state}
  end

  def handle_disconnect(disconnect_map, state) do
    state |> warn("Disconnected from websocket!")
    unless is_nil disconnect_map[:reason] do
      state |> warn("Disconnect reason: #{inspect disconnect_map[:reason]}")
    end
    state |> warn("Done! Please start a new gateway link.")
    # Disconnected from gateway, so not much else to say here
    {:ok, state}
  end

  def terminate(reason, state) do
    state |> info("Websocket terminating: #{inspect reason}")
    :ok
  end

  #############################
  ## GATEWAY OPCODE HANDLERS ##
  #############################

  defp handle_op(@op_hello, payload, state) do
    d = payload[:d]
    state |> info("Hello!")
    # Start HEARTBEAT once we get HELLO
    send self(), {:heartbeat, d[:heartbeat_interval]}
    trace = d[:_trace]
    state |> info("Trace: #{inspect trace, pretty: true}")
    # Since we've successfully connected, we can start zombie shard detection
    send self(), :check_zombie
    # Finally, fire off an IDENTIFY or a RESUME based on the session state
    {:ok, session_id} = Redis.q ["HGET", @session_key_base, "#{state[:shard_id]}"]
    if session_id == nil or session_id == :undefined do
      # We don't have a session, IDENTIFY
      {:reply, identify(state), %{state | trace: trace}}
    else
      # We do have a session, fetch seqnum and RESUME
      {:ok, seqnum} = Redis.q ["HGET", @seq_key_base, "#{state[:shard_id]}"]
      if seqnum == nil or seqnum == :undefined do
        # In some cases, it's possible that we have a session but not a seqnum
        # If this happens, we just bail out and IDENTIFY
        {:reply, identify(state), %{state | trace: trace}}
      else
        # We're probably good, we can RESUME now
        seqnum = seqnum |> String.to_integer
        {:reply, resume(state, session_id, seqnum), %{state | trace: trace}}
      end
    end
  end

  defp handle_op(@op_dispatch, payload, state) do
    # Whenever we get a DISPATCH event, we need to update the seqnum based on
    # what the gateway tells us
    # TODO: Check against old seqnum to make sure the gateway isn't telling us to go time-traveling
    Redis.q ["HSET", @seq_key_base, "#{state[:shard_id]}", payload[:s]]
    t = payload[:t]
    handle_event t, payload, payload[:d], state
  end

  defp handle_op(@op_heartbeat_ack, _payload, state) do
    state |> debug("HEARTBEAT_ACK")
    {:noreply, nil, state}
  end

  defp handle_op(@op_invalid_session, payload, state) do
    can_resume = payload[:d]
    state |> info("INVALID SESSION: can resume = #{inspect can_resume}")
    unless can_resume do
      # We can't resume the session, delete it so that next run gets a full IDENTIFY flow
      Redis.q ["HDEL", @session_key_base, "#{state[:shard_id]}"]
      Redis.q ["HDEL", @seq_key_base, "#{state[:shard_id]}"]
    end
    {:terminate, nil, state}
  end

  ############################
  ## GATEWAY EVENT HANDLERS ##
  ############################

  def handle_event(:READY, _payload, d, state) do
    state |> info("READY! Welcome to Discord!")
    # Update session and seqnum
    Redis.q ["HSET", @session_key_base, "#{state[:shard_id]}", d[:session_id]]
    # Extract info about ourself
    user = d[:user]
    guilds = d[:guilds]
    v = d[:v]
    state |> info("Logged in to gateway v#{v}, #{length guilds} guilds")
    state |> info("We are: '#{user[:username]}##{user[:discriminator]}'")
    # Alert the cluster that we finished booting, backing off a bit to allow
    # for proper IDENTIFY ratelimit handling
    send state[:cluster], {:shard_booted, state[:shard_id]}
    {:noreply, nil, state}
  end

  def handle_event(:RESUMED, _payload, _d, state) do
    state |> info("RESUMED! Welcome back to Discord!")
    send state[:cluster], {:shard_resumed, state[:shard_id]}
    {:noreply, nil, state}
  end

  ## Guild payloads ##
  def handle_event(:GUILD_CREATE, _payload, d, state) do
    {_presences, d} = Map.pop d, :presences
    {_voice_states, d} = Map.pop d, :voice_states
    {members, d} = Map.pop d, :members
    guild = :erlang.term_to_binary d
    # Update guild
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], guild]
    # Update member chunks
    members |> Enum.chunk_every(1000)
            |> Enum.each(fn(chunk) ->
                Redis.t(fn(w) ->
                    Enum.each(chunk, fn(member) ->
                        {user, new_member} = Map.pop member, :user
                        m = new_member
                            |> Map.put(:user, user[:id])
                            |> :erlang.term_to_binary
                        Redis.q w, ["HSET", "g:cache:#{state[:shard_id]}:guild:#{d[:id]}:members", user[:id], m]
                        Redis.q w, ["HSET", "g:cache:users", user[:id], user]
                      end)
                  end)
              end)
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_UPDATE, _payload, d, state) do
    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", d[:id]]
    old_guild = :erlang.binary_to_term res
    new_guild = Map.merge old_guild, d
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_DELETE, _payload, d, state) do
    if Map.has_key?(d, :unavailable) do
      unless d[:unavailable] do
        # Guild deleted and not unavailable, remove from cache
        Redis.q ["HDEL", "g:cache:#{state[:shard_id]}:guild", d[:id]]
      end
    end
    {:noreply, nil, state}
  end

  ## Member payloads
  def handle_event(:GUILD_MEMBER_ADD, _payload, d, state) do
    # d is member with a guild_id field
    {user, member} = Map.pop d, :user
    m = member
        |> Map.put(:user, user[:id])
        |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild:#{d[:guild_id]}:members", user[:id], m]
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_MEMBER_UPDATE, _payload, d, state) do
    # d is
    # %{
    #   guild_id: meme,
    #   roles: [meme, meme, meme],
    #   user: {meme: meme},
    #   nick: "meme"
    # }
    {user, member} = Map.pop d, :user
    member = member |> Map.put(:user, user[:id])
    {:ok, old_member} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild:#{d[:guild_id]}:members", user[:id]]
    new_member = old_member |> Map.put(:roles, member[:roles])
                            |> Map.put(:nick, member[:nick])
    m = new_member |> :erlang.term_to_binary()
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild:#{d[:guild_id]}:members", user[:id], m]
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_MEMBER_REMOVE, _payload, d, state) do
    # d is user and guild_id field
    {user, _} = Map.pop d, :user
    Redis.q ["HDEL", "g:cache:#{state[:shard_id]}:guild:#{d[:guild_id]}:members", user[:id]]
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_MEMBERS_CHUNK, _payload, d, state) do
    Redis.t(fn(w) ->
      Enum.each(d[:members], fn(member) ->
          {user, member} = Map.pop member, :user
          m = member
              |> Map.put(:user, user[:id])
              |> :erlang.term_to_binary
          Redis.q w, ["HSET", "g:cache:#{state[:shard_id]}:guild:#{d[:id]}:members", user[:id], m]
        end)
      end)
    {:noreply, nil, state}
  end

  ## Channel payloads ##
  def handle_event(:CHANNEL_CREATE, _payload, d, state) do
    # d is a channel object
    channel = d
    guild_id = d[:guild_id]
    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", guild_id]
    old_guild = :erlang.binary_to_term res
    new_channels = old_guild[:channels] ++ [channel]
    # TODO: Is this the right sort order?
    new_channels = new_channels |> Enum.sort(fn(c1, c2) -> c1.position < c2.position end)
    new_guild = %{old_guild | channels: new_channels}
                |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]
    {:noreply, nil, state}
  end
  def handle_event(:CHANNEL_UPDATE, _payload, d, state) do
    # d is a channel object
    channel = d
    guild_id = d[:guild_id]

    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", guild_id]
    old_guild = :erlang.binary_to_term res
    old_channels = old_guild[:channel]
    idx = old_channels |> Enum.find_index(fn(x) -> x[:id] == channel[:id] end)
    new_channels = old_channels |> List.insert_at(idx, channel)
                          # TODO: Is this the right sort order?
                          |> Enum.sort(fn(r1, r2) -> r1.position < r2.position end)
    new_guild = %{old_guild | channels: new_channels}
                |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]
    {:noreply, nil, state}
  end
  def handle_event(:CHANNEL_DELETE, _payload, d, state) do
    # d is a channel object
    channel_id = d[:id]
    guild_id = d[:guild_id]
    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", guild_id]
    old_guild = :erlang.binary_to_term res
    new_channels = old_guild[:channels] |> Enum.filter(fn(e) -> e[:id] != channel_id end)
    new_guild = %{old_guild | channels: new_channels}
                |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]

    {:noreply, nil, state}
  end

  ## Role payloads ##
  def handle_event(:GUILD_ROLE_CREATE, _payload, d, state) do
    # d is a role object and a guild_id field
    role = d[:role]
    guild_id = d[:guild_id]
    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", guild_id]
    old_guild = :erlang.binary_to_term res
    new_roles = old_guild[:roles] ++ [role]
    # TODO: Is this the right sort order?
    new_roles = new_roles |> Enum.sort(fn(r1, r2) -> r1.position < r2.position end)
    new_guild = %{old_guild | roles: new_roles}
                |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_ROLE_UPDATE, _payload, d, state) do
    # d is a role object and a guild_id field
    role = d[:role]
    guild_id = d[:guild_id]
    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", guild_id]
    old_guild = :erlang.binary_to_term res
    old_roles = old_guild[:roles]
    idx = old_roles |> Enum.find_index(fn(x) -> x[:id] == role[:id] end)
    new_roles = old_roles |> List.insert_at(idx, role)
                          # TODO: Is this the right sort order?
                          |> Enum.sort(fn(r1, r2) -> r1.position < r2.position end)
    new_guild = %{old_guild | roles: new_roles}
                |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]
    {:noreply, nil, state}
  end
  def handle_event(:GUILD_ROLE_DELETE, _payload, d, state) do
    # d is a role_id field and a guild_id field
    role_id = d[:role_id]
    guild_id = d[:guild_id]
    {:ok, res} = Redis.q ["HGET", "g:cache:#{state[:shard_id]}:guild", guild_id]
    old_guild = :erlang.binary_to_term res
    new_roles = old_guild[:roles] |> Enum.filter(fn(e) -> e[:id] != role_id end)
    new_guild = %{old_guild | roles: new_roles}
                |> :erlang.term_to_binary
    Redis.q ["HSET", "g:cache:#{state[:shard_id]}:guild", d[:id], new_guild]
    {:noreply, nil, state}
  end

  ## User payloads ##
  def handle_event(:USER_UPDATE, _payload, _d, state) do
    # TODO: How much do I even care about this?
    {:noreply, nil, state}
  end
  def handle_event(:PRESENCE_UPDATE, _payload, d, state) do
    # This is the worst one ;-;
    # d is
    # %{
    #   user: %{},
    #   roles: [1, 2, 3, 4],
    #   game: %{},
    #   guild_id: 1234,
    #   status: "whatever"
    # }
    # Because Discord:tm:, the user object may be partial. At the very least,
    # it will have an `id` field. Any fields contained in the user object are
    # fields that the user changed, and need to be updated on the cached user.
    #
    # TODO: Using the roles field to enforce roles on the member object?
    user = d[:user]
    # This could be updating any of: username, discriminator, avatar
    if Map.has_key?(user, :username) or Map.has_key?(user, :discriminator) or Map.has_key?(user, :avatar) do
      # User has an updatable field, so update cache
      {:ok, old_user} = Redis.q ["HGET", "g:cache:users", user[:id]]

      new_user = old_user |> maybe_update_user(user, :username)
                          |> maybe_update_user(user, :discriminator)
                          |> maybe_update_user(user, :avatar)
      # Update cache
      Redis.q ["HSET", "g:cache:users", user[:id], new_user]
    end
    {:noreply, nil, state}
  end
  defp maybe_update_user(user, payload, key) do
    if Map.has_key?(payload, key) do
      user |> Map.put(key, payload[key])
    else
      user
    end
  end

  def handle_event(event, payload, _d, state) do
    suffix = event |> Atom.to_string |> String.downcase
    GenServer.cast :q_backend, {:queue, payload, suffix}
    state |> warn("Unknown DISPATCH type: #{event}")
    {:noreply, nil, state}
  end

  #######################
  ## GATEWAY LIFECYCLE ##
  #######################

  def handle_info({:heartbeat, interval} = message, state) do
    state |> debug("HEARTBEAT")
    payload = binary_payload @op_heartbeat, state[:seq]
    Process.send_after self(), message, interval
    {:reply, {:binary, payload}, state}
  end

  def handle_info(:check_zombie, state) do
    last = state[:last_event]
    now = :os.system_time :millisecond
    if now - last >= @zombie_threshold do
      # Zombie! Terminate and let the shard get rescheduled
      state |> warn("Connection went zombie, rescheduling shard...")
      {:close, state}
    else
      # Check once a second is probably reasonable
      Process.send_after self(), :check_zombie, 1000
      {:ok, state}
    end
  end

  #####################
  ## GATEWAY HELPERS ##
  #####################

  defp identify(state) do
    state |> info("Identifying as [#{inspect state[:shard_id]}, #{inspect state[:shard_count]}]...")
    data = %{
      "token" => state[:token],
      "properties" => %{
        "$os" => "BEAM",
        "$browser" => "samantha",
        "$device" => "samantha"
      },
      "compress" => false,
      "large_threshold" => @large_threshold,
      "shard" => [state[:shard_id], state[:shard_count]],
    }
    payload = binary_payload @op_identify, data
    {:binary, payload}
  end

  defp resume(state, session_id, seq) do
    state |> info("Resuming from seq #{inspect seq}")
    payload = binary_payload @op_resume, %{
      "session_id" => session_id,
      "token" => state[:token],
      "seq" => seq,
      "properties" => %{
        "$os" => "BEAM",
        "$browser" => "samantha",
        "$device" => "samantha"
      },
      "compress" => false,
      "shard" => [state[:shard_id], state[:shard_count]],
    }
    {:binary, payload}
  end

  def binary_payload(op, data, seq_num \\ nil, event_name \\ nil) do
    payload_base(op, data, seq_num, event_name)
    |> :erlang.term_to_binary
  end

  def payload_base(op, data, seq_num, event_name) do
    payload = %{"op" => op, "d" => data}
    payload
    |> update_payload(seq_num, "s", seq_num)
    |> update_payload(event_name, "t", seq_num)
  end

  defp update_payload(payload, var, key, value) do
    if var do
      Map.put(payload, key, value)
    else
      payload
    end
  end
end
