# G

Distributed, cacheless Discord bot sharding.

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
Specifically, I still need to implement a proper event queueing system so backend workers can recv events, as well as 
session-stealing to minimize downtime. 

### Session stealing?

Session-stealing is a useful trick to help minimize bot downtime. Rather than have to go through the full connect-and-identify
flow, you can "steal" the session from a previous shard with the same id / shard total, and resume the session on a new shard 
(potentially even on a different node!) so that you can continue your shard's session without any downtime. 

## Node IDs

G uses [Raindrop](https://github.com/queer/raindrop) for fetching snowflake IDs for many things. Eventually this may be a proper
"pluggable" thing. 

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

## TODO

- Proper session stealing
- Proper backend event queueing
- Shard handoff over nodes probably doesn't work right
- Some sort of standard for external cache workers
- Persist session / seqnum in redis
- Option for member chunking