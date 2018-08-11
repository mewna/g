# G

Distributed, cacheless* Discord bot sharding.

## Wait what?

Discord enforces sharding your bot as the number of servers its on gets bigger. Having all of your shards in a single process
is a huge risk to uptime though, as the process dying effectively kills your entire application. However, distributing these
shards has always been a huge pain due to state coordination. That is, until now. 

## How does it work?

When the nodes come up, a master node is elected. Each node also creates a "cluster worker" that handles spawning shards. Once
the master is up, it starts assigning shards to nodes. Shards are quite simply assigned to whichever node has the least shard 
processes on it at that point in time. 

When a shard goes down, the master node is signaled, and will reassign the shard to a new node as necessary. This will also
balance your node cluster over time. Later, it is planned that the master can proactively handle balancing shards across the
cluster. 

While this is a fully-functional Discord bot gateway lib. in its current state, a few vital pieces of functionality are missing.
Specifically, I still need to implement a proper event queueing system so backend workers can recv events, as well as a way for
users to sent gateway messages. 

### Session stealing?

Session-stealing is a useful trick to help minimize bot downtime. Rather than have to go through the full connect-and-identify
flow, you can "steal" the session from a previous shard with the same id / shard total, and resume the session on a new shard 
(potentially even on a different node!) so that you can continue your shard's session without any downtime. 

## Cacheless but with an asterisk?

**G does not store its Discord entity cache in-memory**. Caching is done externally with Redis. This is currently *mandatory* but
will likely become optional someday. Ideally we could run entirely without cache - and the recent 
[lazy guild changes](https://github.com/discordapp/discord-api-docs/issues/582) make this possible for a lot of use cases, but my 
applications need some amount of cache that can't be faked without a lot of 429s.

Redis cache keys are stored as hashes:
```
$ indicates a variable

guild   - g:cache:$shard:guild $id data
channel - stored on the guild object
role    - stored on the guild object
member  - g:cache:$shard:guild:$id:member $id data
user    - g:cache:user $id data
```
Note that the user data is NOT stored in a per-shard cache. This is to avoid user duplication (which can easily be millions of users);
guilds / channels / roles / members are *not* global data (as a guild the bot is in is guaranteed to be on exactly 1 shard), so those
are stored as per-shard caches. *If a shard has to do a full `IDENTIFY`, existing data cached for that shard is __deleted__*. 

Example data:
```Javascript
// Guild example
// Stored at g:cache:1:guild 487256022529037787
{
    "id": 487256022529037787,
    "name": "my cool guild",
    // ...
    "channels": [
        {
            "id": 487256022529037787
            "name": "general",
            // ...
        }
    ],
    "roles": [
        {
            "id": 487256022529037787,
            "name": "everyone",
            // ...
        }
    ]
}
// Member example
// Stored at g:cache:1:guild:487256022529037787:members 477256022529037786
{
    "id": 477256022529037786,
    "nick": null,
    // ...
}

// User example
// Stored at g:cache:users 477256022529037786
{
    "id": 477256022529037786,
    "username": "my cool user",
    "discriminator": "1234"
}
```

### ytho

A dedicated external process for caching is problematic because it gives the potential for cache quickly becoming desynchronized
with how it actually should be. However, passing off state between shard instances is a huge pain - a single shard's cache can
easily be 200MB+, and as you have more shards this memory usage increases very quickly. Instead, we can store data externally in 
Redis and solve many problems. 

## Shard rebalancing

Suppose you have `M` nodes, and a target shard count `N`. In an ideal world, each node would have exactly `N / M` shards on it. 
However, this isn't always possible. Suppose a case of `M = 4` and `N = 50`; the ideal case is each node having exactly 12.5
shards on it, which is impossible for obvious reasons. To solve this, we set a **threshold** of shards / node, so that the 
cluster will be *approximately* balanced. Specifically, the master will try to balance shards across the cluster such that 
each node will have `round(M / N) ± 1` shards on it. 
**This will only work if you have a shard count and a node count that actually fit within these numbers.**

## Node IDs

G uses [Raindrop](https://github.com/queer/raindrop) for fetching snowflake IDs for many things. Eventually this may be a proper
"pluggable" thing. 

## What about voice support?

Voice support is a non-goal for G. Feel free to PR your own implementation, but I won't be making one. 

## What the heck is with the lack of unit/integration/... tests?

- There is no mock for the Discord API.
- Distributed stuff turns out to be really hard to test.
- The lack of a Discord API mock makes it basically impossible to test a lot of this.

## Usage

Set these environment variables for each node, and run with `mix run --no-halt`. 
```Bash
BOT_TOKEN="aslidufkhaulsidf.asdfgaskjdf.asdfgkjuasdfghadsiujyf"

RAINDROP_URL="https://localhost:1234/"

REDIS_HOST="127.0.0.1"
REDIS_PASS="abcxyz123789"

NODE_NAME="my-awesome-node"
GROUP_NAME="my-awesome-group"
NODE_COOKIE="arjkyhgfvbakuwejsgdfbvkuwjsyhgfbckrujeywhgbakerwjfgaekwjufghbckjudeshcybgrvejwhuysdcbva"
```

### Event queueing

G sends events to [Q](https://github.com/mewna/q)-backed queues in redis. Queue names are structured as `discord:event:event_name`, ex
`discord:event:guild_create`, `discord:event:message_create`, ...

## TODO

- Option for member chunking
- Detect a `^C` of `mix run --no-halt`?
- Protect against the case of a 0-shard node
- Make external caching optional

## Done

- Proper backend event queueing
- Persist session / seqnum in redis
- Proper session stealing
- Zombie shard detection
- Rebalance shards