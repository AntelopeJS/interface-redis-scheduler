-------------------------- MODULE SchedulerState ---------------------------
(***************************************************************************)
(* Task delivery of @antelopejs/interface-redis-scheduler (src/index.ts):  *)
(* listeners started with enableListener(), an app process calling addTask *)
(* and removeTask, one Redis sorted set and the SchedulerUtil channel.     *)
(*                                                                         *)
(* A listener sends every command on the one ioredis client GetClient()    *)
(* returns, so Redis applies them and the listener handles their replies   *)
(* in the order it sent them (fifo). GetClient() returns a promise that is *)
(* already resolved once enableListener() ran (index.ts:89), so the await  *)
(* on it is a microtask: nothing else runs before the command after it is  *)
(* sent, and that send is part of the step that awaited GetClient(). Each  *)
(* other await is one step. Redis applying a command and the listener      *)
(* handling its reply are one step. Time moves in ticks; task t is due at  *)
(* tick t.                                                                 *)
(*                                                                         *)
(* This module holds the constants, variables, types, Redis helpers and   *)
(* Init. SchedulerDelivery.tla holds the steps and the rules.              *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
  Listeners,     \* processes that called enableListener()
  TaskCount,     \* tasks the app adds, once each; task t is due at tick t
  Removable,     \* tasks the app removes with removeTask, once each, after addTask resolved
  Reschedulable, \* tasks the app adds again, due one tick later, once each, after addTask resolved
  PreQueued,     \* TRUE: Init may hold queued tasks, as when a listener restarts
  MaxRetries,    \* MaxRetries (index.ts:16)
  RetryDelay,    \* RetryDelayMs (index.ts:17), in ticks
  MaxTimerDelay, \* MaxTimerDelayMs (index.ts:18), in ticks
  TakeScript     \* TRUE: the take is one Lua script (index.ts:235-244); FALSE: the
                 \* take before #26, ZRANGEBYSCORE then ZREM of what it read

Tasks == 1..TaskCount

(* <<t, 0>> is the member handler:info that addTask writes (index.ts:65-67, *)
(* 162); <<t, n>> is the member RETRY-n:handler:info a failed attempt      *)
(* writes (index.ts:266-270).                                             *)
Members == Tasks \X (0..MaxRetries)

(* A schedule is a member and the score one write gave it. Every write in *)
(* the model gives a member a score no earlier write gave it (task t at t, *)
(* a reschedule at t + 1, each retry member once), so the pair names one *)
(* addTask, reschedule or retry. A rescheduled task that ran twice could *)
(* write the same retry member at the same score twice, so a model with  *)
(* reschedules has no retries.                                           *)
ASSUME Reschedulable = {} \/ MaxRetries = 0

NoTimer == -1
NoMember == <<0, 0>>

VARIABLES
  now,       \* Date.now(), in ticks
  zset,      \* SchedulerUtil.Tasks: each queued member and its score
  cops,      \* commands the app process sent and Redis has not applied yet
  inbox,     \* "update" messages a listener's subscriber got and has not handled yet
  locked,    \* each listener's locked flag (index.ts:201)
  timer,     \* the tick each listener's armed timer fires at, or NoTimer (index.ts:203)
  fifo,      \* each listener's commands on its Redis connection, in the order sent
  busy,      \* each listener's runTasks calls waiting on a task handler
  addState,  \* per task: "no", "sent" (zadd in flight) or "done" (addTask resolved)
  removed,   \* Removable tasks whose removeTask was called
  cancelled, \* tasks whose removeTask deleted the queued member
  rescheduled, \* Reschedulable tasks whose second addTask was called
  written,   \* every schedule a ZADD ever stored
  retired,   \* schedules removeTask deleted or a later ZADD of the member replaced
  takes,     \* how many times a batch took each schedule
  attempts,  \* how many times a handler ran for each task
  outcome    \* per task: "none", "ok" (a handler returned) or "exhausted"

vars == <<now, zset, cops, inbox, locked, timer, fifo, busy, addState,
          removed, cancelled, rescheduled, written, retired, takes, attempts, outcome>>

(* One record shape for every continuation, so TLC compares them freely: *)
(* its kind, the member it is about, a score or a Date.now(), and the     *)
(* schedules of the batch still to run.                                    *)
Cont(k, m, s, rest) == [k |-> k, m |-> m, s |-> s, rest |-> rest]

(* updateTimer() passed `if (locked)` and sent ZRANGE key 0 0            *)
(* (index.ts:212-217).                                                    *)
ZrangeSent == Cont("zrange", NoMember, 0, {})

(* runTasks() set locked and sent the take script with Date.now()        *)
(* (index.ts:252-254, 242).                                               *)
TakeSent(at) == Cont("take", NoMember, at, {})

Kinds == {"zrange", "take", "zrem", "retry", "handler"}
Conts == [k : Kinds, m : Members \cup {NoMember}, s : Int,
          rest : SUBSET (Members \X Int)]

TypeOK ==
  /\ now \in Nat
  /\ DOMAIN zset \subseteq Members /\ \A m \in DOMAIN zset : zset[m] \in Nat
  /\ cops \subseteq [op : {"zadd", "rezadd", "publish", "republish", "zrem"}, t : Tasks]
  /\ inbox \in [Listeners -> Nat]
  /\ locked \in [Listeners -> BOOLEAN]
  /\ timer \in [Listeners -> Nat \cup {NoTimer}]
  /\ \A l \in Listeners : \A i \in 1..Len(fifo[l]) : fifo[l][i] \in Conts
  /\ \A l \in Listeners : \A i \in 1..Len(busy[l]) : busy[l][i] \in Conts
  /\ addState \in [Tasks -> {"no", "sent", "done"}]
  /\ removed \subseteq Removable /\ cancelled \subseteq Tasks
  /\ rescheduled \subseteq Reschedulable
  /\ written \subseteq Members \X Nat /\ retired \subseteq written
  /\ DOMAIN takes \subseteq written /\ \A x \in DOMAIN takes : takes[x] \in Nat
  /\ attempts \in [Tasks -> Nat]
  /\ outcome \in [Tasks -> {"none", "ok", "exhausted"}]

ZAdd(z, m, s) == [x \in DOMAIN z \cup {m} |-> IF x = m THEN s ELSE z[x]]

(* A ZADD of member m at score s: Redis stores it, and the schedule it     *)
(* replaces, if m was queued, is retired.                                 *)
Write(m, s) ==
  /\ zset' = ZAdd(zset, m, s)
  /\ written' = written \cup {<<m, s>>}
  /\ retired' = IF m \in DOMAIN zset THEN retired \cup {<<m, zset[m]>>} ELSE retired

(* The schedules of the queued members.                                  *)
Queued(z) == {<<m, z[m]>> : m \in DOMAIN z}

(* A batch takes each schedule in it once more.                          *)
Take(tk, batch) ==
  [x \in DOMAIN tk \cup batch |->
     (IF x \in DOMAIN tk THEN tk[x] ELSE 0) + (IF x \in batch THEN 1 ELSE 0)]
ZRem(z, ms) == [x \in DOMAIN z \ ms |-> z[x]]
Min(a, b) == IF a <= b THEN a ELSE b
RemoveAt(s, i) == SubSeq(s, 1, i - 1) \o SubSeq(s, i + 1, Len(s))

(* ZRANGE key 0 0: the member with the lowest score. *)
First(z) == CHOOSE m \in DOMAIN z : \A x \in DOMAIN z : z[m] <= z[x]

(* The next member of a taken batch: ZRANGEBYSCORE returns them by score. *)
NextOf(rest) == CHOOSE p \in rest : \A q \in rest : p[2] <= q[2]

Init ==
  /\ now = 0
  /\ \E queued \in (IF PreQueued THEN SUBSET Tasks ELSE {{}}) :
       /\ zset = [m \in {<<t, 0>> : t \in queued} |-> m[1]]
       /\ addState = [t \in Tasks |-> IF t \in queued THEN "done" ELSE "no"]
       /\ written = Queued(zset)
  /\ cops = {}
  /\ inbox = [l \in Listeners |-> 0]
  /\ locked = [l \in Listeners |-> FALSE]
  /\ timer = [l \in Listeners |-> NoTimer]
  /\ fifo = [l \in Listeners |-> <<ZrangeSent>>]                 \* index.ts:101
  /\ busy = [l \in Listeners |-> <<>>]
  /\ removed = {}
  /\ cancelled = {}
  /\ rescheduled = {}
  /\ retired = {}
  /\ takes = <<>>
  /\ attempts = [t \in Tasks |-> 0]
  /\ outcome = [t \in Tasks |-> "none"]

=============================================================================
