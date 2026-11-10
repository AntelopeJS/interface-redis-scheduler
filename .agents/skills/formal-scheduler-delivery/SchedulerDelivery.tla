------------------------- MODULE SchedulerDelivery -------------------------
(* The steps of the app and the listeners, and the delivery rules, over   *)
(* the state SchedulerState.tla declares. Its header says what one step   *)
(* models.                                                                 *)
EXTENDS SchedulerState

(* After a batch member settles, runTasks hands the next one to its       *)
(* handler (index.ts:286-290), or clears locked and calls updateTimer,    *)
(* which sends ZRANGE (index.ts:277-280, 228-233). The handler's own work *)
(* is the busy step that follows.                                         *)
NextMember(l, base, rest, queue) ==
  IF rest = {}
  THEN /\ locked' = [locked EXCEPT ![l] = FALSE]                 \* index.ts:278
       /\ fifo' = [fifo EXCEPT ![l] = Append(queue, ZrangeSent)] \* index.ts:280
       /\ busy' = [busy EXCEPT ![l] = base]
       /\ UNCHANGED attempts
  ELSE LET p == NextOf(rest) IN
       /\ busy' = [busy EXCEPT ![l] = Append(base,
                     Cont("handler", p[1], p[2], rest \ {p}))]  \* index.ts:289-290
       /\ fifo' = [fifo EXCEPT ![l] = queue]
       /\ attempts' = [attempts EXCEPT ![p[1][1]] = @ + 1]
       /\ UNCHANGED locked

(* ------------------------------ the app -------------------------------- *)

(* What a step of the app leaves alone, apart from what it names.         *)
AppKeeps == <<now, inbox, locked, timer, fifo, busy, takes, attempts, outcome>>

(* addTask: the handler is registered (index.ts:166), AddTaskScript is   *)
(* sent (index.ts:170-178).                                              *)
AddTaskCall(t) ==
  /\ addState[t] = "no"
  /\ addState' = [addState EXCEPT ![t] = "sent"]
  /\ cops' = cops \cup {[op |-> "zadd", t |-> t]}
  /\ UNCHANGED <<zset, removed, cancelled, rescheduled, written, retired>>
  /\ UNCHANGED AppKeeps

(* Redis runs AddTaskScript; addTask sends the publish when the member   *)
(* comes first or the first member is due, since the app process runs no *)
(* batch and its locked is false (index.ts:171-181).                     *)
AddTaskZadd(t) ==
  /\ [op |-> "zadd", t |-> t] \in cops
  /\ Write(<<t, 0>>, t)
  /\ addState' = [addState EXCEPT ![t] = "done"]
  /\ \E first \in PublishAfterWrite(zset, <<t, 0>>, t) :
       cops' = (cops \ {[op |-> "zadd", t |-> t]})
                 \cup (IF first THEN {[op |-> "publish", t |-> t]} ELSE {})
  /\ UNCHANGED <<removed, cancelled, rescheduled>>
  /\ UNCHANGED AppKeeps

(* The app reschedules: addTask again with the same handler and info,    *)
(* due one tick later, so the zadd moves the member's score              *)
(* (index.ts:166-178).                                                    *)
RescheduleCall(t) ==
  /\ t \in Reschedulable \ rescheduled
  /\ addState[t] = "done"
  /\ rescheduled' = rescheduled \cup {t}
  /\ cops' = cops \cup {[op |-> "rezadd", t |-> t]}
  /\ UNCHANGED <<zset, addState, removed, cancelled, written, retired>>
  /\ UNCHANGED AppKeeps

(* Redis applies the reschedule's zadd, which stores the member again if *)
(* a batch already took it; addTask sends the publish when the member   *)
(* comes first or the first member is due (index.ts:171-181).            *)
RescheduleZadd(t) ==
  /\ [op |-> "rezadd", t |-> t] \in cops
  /\ Write(<<t, 0>>, t + 1)
  /\ \E first \in PublishAfterWrite(zset, <<t, 0>>, t + 1) :
       cops' = (cops \ {[op |-> "rezadd", t |-> t]})
                 \cup (IF first THEN {[op |-> "republish", t |-> t]} ELSE {})
  /\ UNCHANGED <<addState, removed, cancelled, rescheduled>>
  /\ UNCHANGED AppKeeps

(* Redis applies a publish: every subscribed listener gets "update"      *)
(* (index.ts:100).                                                         *)
Publish(t) ==
  \E op \in {"publish", "republish"} :
    /\ [op |-> op, t |-> t] \in cops
    /\ cops' = cops \ {[op |-> op, t |-> t]}
    /\ inbox' = [l \in Listeners |-> inbox[l] + 1]
    /\ UNCHANGED <<now, zset, locked, timer, fifo, busy, addState, removed,
                   cancelled, rescheduled, written, retired, takes, attempts, outcome>>

(* removeTask sends zrem (index.ts:212-213).                              *)
RemoveTaskCall(t) ==
  /\ t \in Removable \ removed
  /\ addState[t] = "done"
  /\ removed' = removed \cup {t}
  /\ cops' = cops \cup {[op |-> "zrem", t |-> t]}
  /\ UNCHANGED <<zset, addState, cancelled, rescheduled, written, retired>>
  /\ UNCHANGED AppKeeps

(* zrem deletes the original member only, never a RETRY- member          *)
(* (index.ts:213, 74-76).                                                 *)
RemoveTaskZrem(t) ==
  /\ [op |-> "zrem", t |-> t] \in cops
  /\ cops' = cops \ {[op |-> "zrem", t |-> t]}
  /\ zset' = ZRem(zset, {<<t, 0>>})
  /\ IF <<t, 0>> \in DOMAIN zset
     THEN /\ cancelled' = cancelled \cup {t}
          /\ retired' = retired \cup {<<<<t, 0>>, zset[<<t, 0>>]>>}
     ELSE UNCHANGED <<cancelled, retired>>
  /\ UNCHANGED <<addState, removed, rescheduled, written>>
  /\ UNCHANGED AppKeeps

(* ---------------------------- a listener ------------------------------- *)

(* What a step of a listener leaves alone, apart from what it names.      *)
ListenerKeeps == <<now, cops, addState, removed, cancelled, rescheduled>>

(* The subscriber's "message" handler calls updateTimer, which returns at *)
(* once while locked and sends ZRANGE otherwise (index.ts:101-107, 228-233). *)
NotifyUpdate(l) ==
  /\ inbox[l] > 0
  /\ inbox' = [inbox EXCEPT ![l] = @ - 1]
  /\ fifo' = IF locked[l] THEN fifo
             ELSE [fifo EXCEPT ![l] = Append(@, ZrangeSent)]
  /\ UNCHANGED <<zset, locked, timer, busy, written, retired, takes, attempts, outcome>>
  /\ UNCHANGED ListenerKeeps

(* The armed timer calls runTasks, which returns at once while locked,   *)
(* and otherwise sets locked and sends the take (index.ts:244-245,        *)
(* 270-276, 285).                                                         *)
TimerFires(l) ==
  /\ timer[l] # NoTimer
  /\ timer[l] <= now
  /\ timer' = [timer EXCEPT ![l] = NoTimer]
  /\ IF locked[l]                                                 \* index.ts:271-273
     THEN UNCHANGED <<locked, fifo>>
     ELSE /\ locked' = [locked EXCEPT ![l] = TRUE]                \* index.ts:274
          /\ fifo' = [fifo EXCEPT ![l] = Append(@, TakeSent(now))]
  /\ UNCHANGED <<zset, inbox, busy, written, retired, takes, attempts, outcome>>
  /\ UNCHANGED ListenerKeeps

(* ZRANGE WITHSCORES answers with the first member and its score in one  *)
(* reply (index.ts:233). No member ends updateTimer with no timer armed   *)
(* (index.ts:234-236). A past score calls runTasks now, leaving any armed *)
(* timer armed, and runTasks returns at once while locked (index.ts:238- *)
(* 239, 271-273). A later one replaces the armed timer (index.ts:241-247). *)
ZrangeReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "zrange"
  /\ IF DOMAIN zset = {}
     THEN /\ fifo' = [fifo EXCEPT ![l] = Tail(@)]
          /\ UNCHANGED <<locked, timer>>
     ELSE IF zset[First(zset)] < now /\ locked[l]                  \* index.ts:271-273
     THEN /\ fifo' = [fifo EXCEPT ![l] = Tail(@)]
          /\ UNCHANGED <<locked, timer>>
     ELSE IF zset[First(zset)] < now
     THEN /\ fifo' = [fifo EXCEPT ![l] = Append(Tail(@), TakeSent(now))]
          /\ locked' = [locked EXCEPT ![l] = TRUE]                \* index.ts:274
          /\ UNCHANGED timer
     ELSE /\ fifo' = [fifo EXCEPT ![l] = Tail(@)]
          /\ timer' = [timer EXCEPT ![l] = Min(zset[First(zset)], now + MaxTimerDelay)]
          /\ UNCHANGED locked
  /\ UNCHANGED <<zset, inbox, busy, written, retired, takes, attempts, outcome>>
  /\ UNCHANGED ListenerKeeps

(* The take answers. With TakeScript, Redis removed and returned every   *)
(* member scored at or before the Date.now() it was sent with, in one    *)
(* step (index.ts:251-260). Without it, as before #26, ZRANGEBYSCORE      *)
(* only reads them; an empty read ends the batch, any other sends ZREM of *)
(* the members it read (a8d9d8c^ index.ts:250-252).                       *)
TakeReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "take"
  /\ LET batch == {x \in Queued(zset) : x[2] <= Head(fifo[l]).s} IN
     IF TakeScript \/ batch = {}
     THEN /\ zset' = ZRem(zset, {x[1] : x \in batch})
          /\ takes' = Take(takes, batch)
          /\ NextMember(l, busy[l], batch, Tail(fifo[l]))
     ELSE /\ fifo' = [fifo EXCEPT ![l] =
               Append(Tail(@), Cont("zrem", NoMember, 0, batch))]
          /\ UNCHANGED <<zset, takes, locked, busy, attempts>>
  /\ UNCHANGED <<inbox, timer, written, retired, outcome>>
  /\ UNCHANGED ListenerKeeps

(* The ZREM of the members a take without TakeScript read answers:      *)
(* Redis deletes each of them, whatever score it holds now, and the      *)
(* batch runs what was read (a8d9d8c^ index.ts:252-253).                  *)
ZremReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "zrem"
  /\ LET batch == Head(fifo[l]).rest IN
     /\ zset' = ZRem(zset, {x[1] : x \in batch})
     /\ takes' = Take(takes, batch)
     /\ NextMember(l, busy[l], batch, Tail(fifo[l]))
  /\ UNCHANGED <<inbox, timer, written, retired, outcome>>
  /\ UNCHANGED ListenerKeeps

(* The retry zadd answers (index.ts:297-303); the loop moves on.         *)
RetryZaddReply(l) ==
  /\ fifo[l] # <<>>
  /\ Head(fifo[l]).k = "retry"
  /\ LET c == Head(fifo[l]) IN
     /\ Write(c.m, c.s)
     /\ NextMember(l, busy[l], c.rest, Tail(fifo[l]))
  /\ UNCHANGED <<inbox, timer, takes, outcome>>
  /\ UNCHANGED ListenerKeeps

(* A handler returns (index.ts:290).                                     *)
HandlerReturns(l) ==
  \E i \in 1..Len(busy[l]) :
    LET c == busy[l][i] IN
    /\ outcome' = [outcome EXCEPT ![c.m[1]] = "ok"]
    /\ NextMember(l, RemoveAt(busy[l], i), c.rest, fifo[l])
    /\ UNCHANGED <<zset, inbox, timer, written, retired, takes>>
    /\ UNCHANGED ListenerKeeps

(* A handler throws (index.ts:292-305): below MaxRetries the task is     *)
(* queued again as RETRY-n+1 RetryDelay later, else it is dropped.       *)
HandlerThrows(l) ==
  \E i \in 1..Len(busy[l]) :
    LET c == busy[l][i]
        n == c.m[2]
    IN
    IF n < MaxRetries                                             \* index.ts:295-296
    THEN /\ busy' = [busy EXCEPT ![l] = RemoveAt(@, i)]
         /\ fifo' = [fifo EXCEPT ![l] = Append(@,
               Cont("retry", <<c.m[1], n + 1>>, now + RetryDelay, c.rest))]
         /\ UNCHANGED <<zset, inbox, locked, timer, written, retired, takes, attempts, outcome>>
         /\ UNCHANGED ListenerKeeps
    ELSE /\ outcome' = [outcome EXCEPT ![c.m[1]] = "exhausted"]
         /\ NextMember(l, RemoveAt(busy[l], i), c.rest, fifo[l])
         /\ UNCHANGED <<zset, inbox, timer, written, retired, takes>>
         /\ UNCHANGED ListenerKeeps

(* Time passes while a queued member or an armed timer is still ahead.  *)
Tick ==
  /\ \/ \E m \in DOMAIN zset : zset[m] > now
     \/ \E l \in Listeners : timer[l] > now
  /\ now' = now + 1
  /\ UNCHANGED <<zset, cops, inbox, locked, timer, fifo, busy, addState, removed,
                 cancelled, rescheduled, written, retired, takes, attempts, outcome>>

(* Every step an actor or the clock can take. *)
Busy ==
  \/ \E t \in Tasks :
       \/ AddTaskCall(t) \/ AddTaskZadd(t) \/ Publish(t)
       \/ RescheduleCall(t) \/ RescheduleZadd(t)
       \/ RemoveTaskCall(t) \/ RemoveTaskZrem(t)
  \/ \E l \in Listeners :
       \/ NotifyUpdate(l) \/ TimerFires(l)
       \/ ZrangeReply(l) \/ TakeReply(l) \/ ZremReply(l)
       \/ RetryZaddReply(l) \/ HandlerReturns(l) \/ HandlerThrows(l)
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

(* A schedule is handed to a batch at most once: two batches, on one    *)
(* listener or on two, never both take it.                               *)
HandOffOnce == \A x \in DOMAIN takes : takes[x] <= 1

(* No schedule leaves the queue unaccounted for: each one a ZADD stored  *)
(* is still queued, was handed to a batch, was deleted by removeTask, or *)
(* was replaced by a later ZADD of its member.                           *)
NoDroppedTask ==
  \A x \in written : x \in Queued(zset) \cup DOMAIN takes \cup retired

(* How many schedules of task t's handler:info member batches took: one *)
(* per addTask or reschedule that ran.                                   *)
Runs(t) == Cardinality({x \in DOMAIN takes : x[1] = <<t, 0>>})

(* A task's handler runs at most MaxRetries + 1 times for each schedule *)
(* of it that ran.                                                       *)
AttemptsBounded == \A t \in Tasks : attempts[t] <= (MaxRetries + 1) * Runs(t)

(* A task is given up only after its handler ran MaxRetries + 1 times:  *)
(* runTasks "includes automatic retry logic for failed tasks"            *)
(* (index.ts:265). With AttemptsBounded, a task never rescheduled is     *)
(* given up after exactly MaxRetries + 1 runs.                           *)
RetriedBeforeGivingUp ==
  \A t \in Tasks : outcome[t] = "exhausted" => attempts[t] >= MaxRetries + 1

(* A listener runs one task handler at a time: locked exists "to prevent *)
(* concurrent task execution" (index.ts:216-217, 271-273).               *)
NoOverlapOnInstance == \A l \in Listeners : Len(busy[l]) <= 1

(* Nothing is left queued, and every added task that removeTask did not *)
(* delete was handled, or used up its retries.                           *)
Delivered ==
  /\ DOMAIN zset = {}
  /\ \A t \in Tasks : addState[t] = "done" /\ t \notin cancelled => outcome[t] # "none"

(* Once nothing can happen any more, every task is delivered. The shared *)
(* runner checks invariants only, so this states the liveness rule       *)
(* NoLostTask in the states where every fair behaviour of the model      *)
(* ends: under weak fairness a behaviour leaves no state where a step is *)
(* enabled, and the model has no cycle, so every fair behaviour ends in  *)
(* a Quiescent state.                                                    *)
NoLostTask == Quiescent => Delivered

=============================================================================
