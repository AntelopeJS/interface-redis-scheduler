------------------------- MODULE SchedulerDelivery -------------------------
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
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
  Listeners,     \* processes that called enableListener()
  TaskCount,     \* tasks the app adds, once each; task t is due at tick t
  Removable,     \* tasks the app removes with removeTask, once each, after addTask resolved
  PreQueued,     \* TRUE: Init may hold queued tasks, as when a listener restarts
  MaxRetries,    \* MaxRetries (index.ts:16)
  RetryDelay,    \* RetryDelayMs (index.ts:17), in ticks
  MaxTimerDelay  \* MaxTimerDelayMs (index.ts:18), in ticks

Tasks == 1..TaskCount

(* <<t, 0>> is the member handler:info that addTask writes (index.ts:65-67, *)
(* 162); <<t, n>> is the member RETRY-n:handler:info a failed attempt      *)
(* writes (index.ts:267-271).                                             *)
Members == Tasks \X (0..MaxRetries)

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
  takes,     \* how many times the take script took each member
  attempts,  \* how many times a handler ran for each task
  outcome    \* per task: "none", "ok" (a handler returned) or "exhausted"

vars == <<now, zset, cops, inbox, locked, timer, fifo, busy,
          addState, removed, cancelled, takes, attempts, outcome>>

(* One record shape for every continuation, so TLC compares them freely: *)
(* its kind, the member it is about, a score or a Date.now(), and the     *)
(* members of the batch still to run with their scores.                   *)
Cont(k, m, s, rest) == [k |-> k, m |-> m, s |-> s, rest |-> rest]

(* updateTimer() passed `if (locked)` and sent ZRANGE key 0 0            *)
(* (index.ts:210-215).                                                    *)
ZrangeSent == Cont("zrange", NoMember, 0, {})

(* runTasks() set locked and sent the take script with Date.now()        *)
(* (index.ts:253-255, 243).                                               *)
TakeSent(at) == Cont("take", NoMember, at, {})

Kinds == {"zrange", "zscore", "take", "retry", "handler"}
Conts == [k : Kinds, m : Members \cup {NoMember}, s : Int,
          rest : SUBSET (Members \X Int)]

TypeOK ==
  /\ now \in Nat
  /\ DOMAIN zset \subseteq Members /\ \A m \in DOMAIN zset : zset[m] \in Nat
  /\ cops \subseteq [op : {"zadd", "publish", "zrem"}, t : Tasks]
  /\ inbox \in [Listeners -> Nat]
  /\ locked \in [Listeners -> BOOLEAN]
  /\ timer \in [Listeners -> Nat \cup {NoTimer}]
  /\ \A l \in Listeners : \A i \in 1..Len(fifo[l]) : fifo[l][i] \in Conts
  /\ \A l \in Listeners : \A i \in 1..Len(busy[l]) : busy[l][i] \in Conts
  /\ addState \in [Tasks -> {"no", "sent", "done"}]
  /\ removed \subseteq Removable /\ cancelled \subseteq Tasks
  /\ takes \in [Members -> Nat]
  /\ attempts \in [Tasks -> Nat]
  /\ outcome \in [Tasks -> {"none", "ok", "exhausted"}]

ZAdd(z, m, s) == [x \in DOMAIN z \cup {m} |-> IF x = m THEN s ELSE z[x]]
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
  /\ cops = {}
  /\ inbox = [l \in Listeners |-> 0]
  /\ locked = [l \in Listeners |-> FALSE]
  /\ timer = [l \in Listeners |-> NoTimer]
  /\ fifo = [l \in Listeners |-> <<ZrangeSent>>]                 \* index.ts:101
  /\ busy = [l \in Listeners |-> <<>>]
  /\ removed = {}
  /\ cancelled = {}
  /\ takes = [m \in Members |-> 0]
  /\ attempts = [t \in Tasks |-> 0]
  /\ outcome = [t \in Tasks |-> "none"]

(* After a batch member settles, runTasks hands the next one to its       *)
(* handler (index.ts:256-260), or clears locked and calls updateTimer,    *)
(* which sends ZRANGE (index.ts:276-277, 210-215). The handler's own work *)
(* is the busy step that follows.                                         *)
NextMember(l, base, rest, queue) ==
  IF rest = {}
  THEN /\ locked' = [locked EXCEPT ![l] = FALSE]                 \* index.ts:276
       /\ fifo' = [fifo EXCEPT ![l] = Append(queue, ZrangeSent)] \* index.ts:277
       /\ busy' = [busy EXCEPT ![l] = base]
       /\ UNCHANGED attempts
  ELSE LET p == NextOf(rest) IN
       /\ busy' = [busy EXCEPT ![l] = Append(base,
                     Cont("handler", p[1], p[2], rest \ {p}))]  \* index.ts:259-260
       /\ fifo' = [fifo EXCEPT ![l] = queue]
       /\ attempts' = [attempts EXCEPT ![p[1][1]] = @ + 1]
       /\ UNCHANGED locked

(* ------------------------------ the app -------------------------------- *)

(* addTask: the handler is registered (index.ts:157), zadd is sent       *)
(* (index.ts:161-162).                                                    *)
AddTaskCall(t) ==
  /\ addState[t] = "no"
  /\ addState' = [addState EXCEPT ![t] = "sent"]
  /\ cops' = cops \cup {[op |-> "zadd", t |-> t]}
  /\ UNCHANGED <<now, zset, inbox, locked, timer, fifo, busy,
                 removed, cancelled, takes, attempts, outcome>>

(* Redis applies the zadd; addTask sends the publish, since the app      *)
(* process runs no batch and its locked is false (index.ts:163-164).      *)
AddTaskZadd(t) ==
  /\ [op |-> "zadd", t |-> t] \in cops
  /\ zset' = ZAdd(zset, <<t, 0>>, t)
  /\ addState' = [addState EXCEPT ![t] = "done"]
  /\ cops' = (cops \ {[op |-> "zadd", t |-> t]}) \cup {[op |-> "publish", t |-> t]}
  /\ UNCHANGED <<now, inbox, locked, timer, fifo, busy,
                 removed, cancelled, takes, attempts, outcome>>

(* Redis applies the publish: every subscribed listener gets "update"    *)
(* (index.ts:91).                                                         *)
Publish(t) ==
  /\ [op |-> "publish", t |-> t] \in cops
  /\ cops' = cops \ {[op |-> "publish", t |-> t]}
  /\ inbox' = [l \in Listeners |-> inbox[l] + 1]
  /\ UNCHANGED <<now, zset, locked, timer, fifo, busy, addState,
                 removed, cancelled, takes, attempts, outcome>>

(* removeTask sends zrem (index.ts:196-197).                              *)
RemoveTaskCall(t) ==
  /\ t \in Removable \ removed
  /\ addState[t] = "done"
  /\ removed' = removed \cup {t}
  /\ cops' = cops \cup {[op |-> "zrem", t |-> t]}
  /\ UNCHANGED <<now, zset, inbox, locked, timer, fifo, busy,
                 addState, cancelled, takes, attempts, outcome>>

(* zrem deletes the original member only, never a RETRY- member          *)
(* (index.ts:197, 65-67).                                                 *)
RemoveTaskZrem(t) ==
  /\ [op |-> "zrem", t |-> t] \in cops
  /\ cops' = cops \ {[op |-> "zrem", t |-> t]}
  /\ zset' = ZRem(zset, {<<t, 0>>})
  /\ cancelled' = IF <<t, 0>> \in DOMAIN zset THEN cancelled \cup {t} ELSE cancelled
  /\ UNCHANGED <<now, inbox, locked, timer, fifo, busy, addState,
                 removed, takes, attempts, outcome>>

(* ---------------------------- a listener ------------------------------- *)

(* The subscriber's "message" handler calls updateTimer, which returns at *)
(* once while locked and sends ZRANGE otherwise (index.ts:92-98, 210-215). *)
NotifyUpdate(l) ==
  /\ inbox[l] > 0
  /\ inbox' = [inbox EXCEPT ![l] = @ - 1]
  /\ fifo' = IF locked[l] THEN fifo
             ELSE [fifo EXCEPT ![l] = Append(@, ZrangeSent)]
  /\ UNCHANGED <<now, zset, cops, locked, timer, busy, addState,
                 removed, cancelled, takes, attempts, outcome>>

(* The armed timer calls runTasks, which never reads locked              *)
(* (index.ts:228-229, 252-255).                                           *)
TimerFires(l) ==
  /\ timer[l] # NoTimer
  /\ timer[l] <= now
  /\ timer' = [timer EXCEPT ![l] = NoTimer]
  /\ locked' = [locked EXCEPT ![l] = TRUE]                        \* index.ts:253
  /\ fifo' = [fifo EXCEPT ![l] = Append(@, TakeSent(now))]
  /\ UNCHANGED <<now, zset, cops, inbox, busy, addState,
                 removed, cancelled, takes, attempts, outcome>>

(* ZRANGE answers: no member ends updateTimer (index.ts:216); a member   *)
(* is followed by ZSCORE of it (index.ts:217).                           *)
ZrangeReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "zrange"
  /\ fifo' = [fifo EXCEPT ![l] =
       IF DOMAIN zset = {} THEN Tail(@)
       ELSE Append(Tail(@), Cont("zscore", First(zset), 0, {}))]
  /\ UNCHANGED <<now, zset, cops, inbox, locked, timer, busy, addState,
                 removed, cancelled, takes, attempts, outcome>>

(* ZSCORE answers. A member gone since the ZRANGE ends updateTimer with  *)
(* no timer armed (index.ts:218-220). A past score calls runTasks now,   *)
(* leaving any armed timer armed (index.ts:222-223). A later one replaces *)
(* the armed timer (index.ts:225-231).                                   *)
ZscoreReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "zscore"
  /\ LET m == Head(fifo[l]).m IN
     IF m \notin DOMAIN zset
     THEN /\ fifo' = [fifo EXCEPT ![l] = Tail(@)]
          /\ UNCHANGED <<locked, timer>>
     ELSE IF zset[m] < now
     THEN /\ fifo' = [fifo EXCEPT ![l] = Append(Tail(@), TakeSent(now))]
          /\ locked' = [locked EXCEPT ![l] = TRUE]                \* index.ts:253
          /\ UNCHANGED timer
     ELSE /\ fifo' = [fifo EXCEPT ![l] = Tail(@)]
          /\ timer' = [timer EXCEPT ![l] = Min(zset[m], now + MaxTimerDelay)]
          /\ UNCHANGED locked
  /\ UNCHANGED <<now, zset, cops, inbox, busy, addState,
                 removed, cancelled, takes, attempts, outcome>>

(* The take script answers: Redis removed and returned every member     *)
(* scored at or before the Date.now() it was sent with (index.ts:236-245). *)
TakeReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "take"
  /\ LET due == {m \in DOMAIN zset : zset[m] <= Head(fifo[l]).s}
         batch == {<<m, zset[m]>> : m \in due}
     IN /\ zset' = ZRem(zset, due)
        /\ takes' = [m \in Members |-> IF m \in due THEN takes[m] + 1 ELSE takes[m]]
        /\ NextMember(l, busy[l], batch, Tail(fifo[l]))
  /\ UNCHANGED <<now, cops, inbox, timer, addState, removed, cancelled, outcome>>

(* The retry zadd answers (index.ts:267-271); the loop moves on.         *)
RetryZaddReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "retry"
  /\ LET c == Head(fifo[l]) IN
     /\ zset' = ZAdd(zset, c.m, c.s)
     /\ NextMember(l, busy[l], c.rest, Tail(fifo[l]))
  /\ UNCHANGED <<now, cops, inbox, timer, addState, removed, cancelled, takes, outcome>>

(* A handler returns (index.ts:260).                                     *)
HandlerReturns(l) ==
  \E i \in 1..Len(busy[l]) :
    LET c == busy[l][i] IN
    /\ outcome' = [outcome EXCEPT ![c.m[1]] = "ok"]
    /\ NextMember(l, RemoveAt(busy[l], i), c.rest, fifo[l])
    /\ UNCHANGED <<now, zset, cops, inbox, timer, addState,
                   removed, cancelled, takes>>

(* A handler throws (index.ts:262-273): below MaxRetries the task is     *)
(* queued again as RETRY-n+1 RetryDelay later, else it is dropped.       *)
HandlerThrows(l) ==
  \E i \in 1..Len(busy[l]) :
    LET c == busy[l][i]
        n == c.m[2]
    IN
    IF n < MaxRetries                                             \* index.ts:265-266
    THEN /\ busy' = [busy EXCEPT ![l] = RemoveAt(@, i)]
         /\ fifo' = [fifo EXCEPT ![l] = Append(@,
               Cont("retry", <<c.m[1], n + 1>>, now + RetryDelay, c.rest))]
         /\ UNCHANGED <<now, zset, cops, inbox, locked, timer, addState,
                        removed, cancelled, takes, attempts, outcome>>
    ELSE /\ outcome' = [outcome EXCEPT ![c.m[1]] = "exhausted"]
         /\ NextMember(l, RemoveAt(busy[l], i), c.rest, fifo[l])
         /\ UNCHANGED <<now, zset, cops, inbox, timer, addState,
                        removed, cancelled, takes>>

(* Time passes while a queued member or an armed timer is still ahead.  *)
Tick ==
  /\ \/ \E m \in DOMAIN zset : zset[m] > now
     \/ \E l \in Listeners : timer[l] > now
  /\ now' = now + 1
  /\ UNCHANGED <<zset, cops, inbox, locked, timer, fifo, busy, addState,
                 removed, cancelled, takes, attempts, outcome>>

(* Every step an actor or the clock can take. *)
Busy ==
  \/ \E t \in Tasks :
       \/ AddTaskCall(t) \/ AddTaskZadd(t) \/ Publish(t)
       \/ RemoveTaskCall(t) \/ RemoveTaskZrem(t)
  \/ \E l \in Listeners :
       \/ NotifyUpdate(l) \/ TimerFires(l)
       \/ ZrangeReply(l) \/ ZscoreReply(l) \/ TakeReply(l) \/ RetryZaddReply(l)
       \/ HandlerReturns(l) \/ HandlerThrows(l)
  \/ Tick

(* Nothing can happen any more: no step of any actor, no tick.           *)
Quiescent == ~ENABLED Busy

(* Once nothing can happen, the system stays as it is. This step keeps  *)
(* /statechart from reading the end as a deadlock.                       *)
Settled == Quiescent /\ UNCHANGED vars

Next == Busy \/ Settled

Spec == Init /\ [][Next]_vars

(* Listeners are interchangeable, so TLC checks one of each mirror pair. *)
ListenerSymmetry == Permutations(Listeners)

(* ------------------------------- rules --------------------------------- *)

(* A member is handed to a batch at most once: two listeners never both *)
(* take it.                                                              *)
HandOffOnce == \A m \in Members : takes[m] <= 1

(* A task's handler runs at most MaxRetries + 1 times.                  *)
AttemptsBounded == \A t \in Tasks : attempts[t] <= MaxRetries + 1

(* A task is given up only after its handler ran MaxRetries + 1 times:  *)
(* runTasks "includes automatic retry logic for failed tasks"            *)
(* (index.ts:250).                                                       *)
RetriedBeforeGivingUp ==
  \A t \in Tasks : outcome[t] = "exhausted" => attempts[t] = MaxRetries + 1

(* A listener runs one task handler at a time: locked exists "to prevent *)
(* concurrent task execution" (index.ts:200-201).                        *)
NoOverlapOnInstance == \A l \in Listeners : Len(busy[l]) <= 1

(* Every added task that removeTask did not delete was handled, or used *)
(* up its retries.                                                       *)
Delivered ==
  \A t \in Tasks : addState[t] = "done" /\ t \notin cancelled => outcome[t] # "none"

(* Once nothing can happen any more, every task is delivered. The shared *)
(* runner checks invariants only, so this states the liveness rule       *)
(* NoLostTask in the states where every fair behaviour of the model      *)
(* ends: under weak fairness a behaviour leaves no state where a step is *)
(* enabled, and the model has no cycle, so every fair behaviour ends in  *)
(* a Quiescent state.                                                    *)
NoLostTask == Quiescent => Delivered

=============================================================================
