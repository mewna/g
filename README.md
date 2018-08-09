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
Specifically, I still need to implement a proper event queueing system so backend workers can recv events, as well as a way for
users to sent gateway messages. 

### Session stealing?

Session-stealing is a useful trick to help minimize bot downtime. Rather than have to go through the full connect-and-identify
flow, you can "steal" the session from a previous shard with the same id / shard total, and resume the session on a new shard 
(potentially even on a different node!) so that you can continue your shard's session without any downtime. 

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

## TODO

- Some sort of standard for external cache workers
- Option for member chunking
- Detect a `^C` of `mix run --no-halt`?
- Rebalance shards
- Protect against the case of a 0-shard node

## Done

- Proper backend event queueing
- Persist session / seqnum in redis
- Proper session stealing
- Zombie shard detection