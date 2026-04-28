# Separate Polling from Nudging in the Agent Loop

## Context

The agent loop conflates three operations into one iteration counter (`&loops`):
1. **Polling** for messages -- should be frequent and cheap (no LLM call)
2. **Processing** -- LLM-driven command chains when there's work to do
3. **Nudging** -- periodic activation for autonomous goal exploration

Currently every iteration (1s) calls the LLM regardless of whether there's new information. This caused spam: the LLM sees the same context repeatedly and generates near-duplicate responses. Dedup/spam-shields are fragile patches.

**The agent should stay busy** -- it's a self-evolving system that explores, queries memory, creates goals, and runs tasks. The fix is not to make it passive, but to make LLM calls information-driven: call the LLM when there's something new to process, and nudge it when it's been quiet.

## Already-implemented changes (keep as-is)

- `lib_llm_ext.py`: `_chatAsiOne` omits user message when empty (line 78-79)
- `memory/prompt.txt`: Send rules (lines 11-16), goal exploration language (line 4)
- `src/channels.metta`: `&lastsend` exact-match dedup on send (line 43-46)

## Design

```
every sleepInterval (1s):
  +-----------------------------------+
  |  Poll for message (cheap)         |
  +----------------+------------------+
                   |
          +--------v--------+
          |  Should call LLM? |
          +--------+--------+
                   |
      +------------+-------------+
      v            v             v
   new msg       &busy        nudge timer
   (reset        (chain:      (idle for
    counter      last iter    wakeupInterval,
    to 50)       produced     reset counter
                 commands)    to maxWakeLoops+1)
      |            |             |
      +------------+-------------+
                   v
           +---------------+      +--------------------+
           |  Call LLM     | ---> |  Commands produced? |
           |  Execute cmds |      +---------+----------+
           |  Update results|          YES  |  NO
           +---------------+       +---+    +---+
                                   v            v
                               &busy=T      &busy=F
                               counter--    set nudge timer
```

**&busy = True**: The agent just executed commands that produced results. The LLM should be called next iteration to see those results and continue its chain.

**&busy = False**: The LLM produced no commands -- it has nothing left to do. The loop just polls for messages until a nudge timer fires or a human message arrives.

**Nudge**: When `&busy` has been False for `wakeupInterval` seconds, activate the agent with a small iteration budget (`maxWakeLoops + 1`). The existing prompt tells it to explore memory, set goals, etc. The LLM chains until it runs out of commands, then goes back to not-busy.

**Safety counter**: `maxNewInputLoops` (50) prevents infinite chains. Separate from the busy/idle logic -- it's a ceiling, not the primary control.

## Changes (1 file: `src/loop.metta`)

### a) `initLoop` -- state variables

Remove:
```metta
(configure spamShield True)          ;; dead code, never read
(change-state! &prevresponse "")     ;; dedup no longer needed
```

Add:
```metta
(change-state! &busy True)           ;; start busy on first boot (initial exploration)
```

Keep: `&loops`, `&prevmsg`, `&lastresults`, `&nextWakeAt` (rename conceptually to "next nudge").

Remove `spamShield` declaration (line 9).

### b) Top of loop -- remove unconditional loop decrement

Current (line 47):
```metta
(change-state! &loops (- (get-state &loops) 1))
```
This runs every non-first iteration. Move the decrement into the LLM-call path only (step f), so idle iterations don't burn the counter.

Replace the `if (== $k 1)` block (lines 44-47):
```metta
;; current
(if (== $k 1) (progn (initLoop) (initMemory) (initChannels))
              (change-state! &loops (- (get-state &loops) 1)))
```
With:
```metta
;; new: only init on first iteration, no unconditional decrement
(if (== $k 1) (progn (initLoop) (initMemory) (initChannels)) _)
```

### c) Activation triggers -- in `let*` bindings

Replace (lines 54-56):
```metta
($_ (if (and (> $k 1) $msgnew)
        (progn (change-state! &loops (maxNewInputLoops))
               (change-state! &prevresponse "")) _))
```
With:
```metta
;; Activate on new human message
($_ (if (and (> $k 1) $msgnew)
        (progn (change-state! &busy True)
               (change-state! &loops (maxNewInputLoops))) _))
;; Nudge: activate when idle for wakeupInterval
($_ (if (and (not (get-state &busy))
             (> (get_time) (get-state &nextWakeAt)))
        (progn (change-state! &busy True)
               (change-state! &loops (+ 1 (maxWakeLoops)))) _))
```

### d) Main gate -- replace loop counter with busy check

Replace (line 57):
```metta
(if (> (get-state &loops) 0)
```
With:
```metta
(if (and (get-state &busy) (> (get-state &loops) 0))
```

### e) Remove `nextWakeAt` reset from inside active path

Remove line 59:
```metta
($_ (change-state! &nextWakeAt (+ (get_time) (wakeupInterval))))
```
The nudge timer is now set only when the agent transitions to not-busy (step f).

### f) Handle empty LLM response + replace dedup with busy/idle transition

Replace line 71 (response validation):
```metta
;; current
($response (if (== "(" (first_char $resp)) $resp (progn (println! $resp) (repr (REMEMBER:OUTPUT_NOTHING_ELSE_THAN: ((skill arg) ...))))))
```
With:
```metta
;; new: non-command output -> empty command list -> agent goes idle
($response (if (and (> (string_length $resp) 0) (== "(" (first_char $resp)))
               $resp
               (progn (if (> (string_length $resp) 0) (println! (NON_COMMAND_OUTPUT: $resp)) _) "()")))
```

Replace lines 72-84 (dedup + command execution):
```metta
;; Remove: $isdup, &prevresponse bindings and if $isdup branch
;; Replace with:
($sexpr (catch (sread $response)))
($_ (change-state! &error ()))
($_ (HandleError MULTI_COMMAND_FAILURE_NOTHING_WAS_DONE_PLEASE_CORRECT_PARENTHESES_AND_USE_QUOTES_AND_RETRY $response $sexpr))
($_ (println! (RESPONSE: $sexpr))))
(if (== $sexpr ())
    ;; No commands -> agent is done, go idle
    (progn (println! (IDLE: no commands, setting nudge timer))
           (change-state! &busy False)
           (change-state! &nextWakeAt (+ (get_time) (wakeupInterval))))
    ;; Commands produced -> execute, stay busy, decrement safety counter
    (let* (($results (RESULTS: (collapse (let $s (superpose $sexpr) (COMMAND_RETURN: ($s (HandleError SINGLE_COMMAND_FORMAT_ERROR_NOTHING_WAS_DONE_PLEASE_FIX_AND_RETRY $s (catch (let $R (eval $s) (py-call (helper.normalize_string $R)))))))))))
           ($_ (println! $results)))
          (progn (if (or $msgnew (not (== $sexpr ()))) (addToHistory $msg $response $sexpr $msgnew) _)
                 (change-state! &lastresults (string-safe (repr $results)))
                 (change-state! &loops (- (get-state &loops) 1)))))
```

### g) Else branch -- safety limit + remove old wake timer

Replace lines 85-86 (old wake timer in else branch):
```metta
;; current
(if (> (get_time) (get-state &nextWakeAt))
    (change-state! &loops (+ 1 (maxWakeLoops))) _)
```
With:
```metta
;; new: if busy but safety counter exhausted -> force idle
(if (get-state &busy)
    (progn (println! (SAFETY_LIMIT: max iterations reached, setting nudge timer))
           (change-state! &busy False)
           (change-state! &nextWakeAt (+ (get_time) (wakeupInterval))))
    _)
```

The wake timer activation is now in step (c) as a `let*` binding.

### h) `memory/prompt.txt` -- no changes

The prompt stays aggressive about goals. The loop handles pacing -- the LLM should always try to do useful work when called. The send rules (lines 11-16) remain as guidance.

## What this changes

| Aspect | Before | After |
|--------|--------|-------|
| LLM calls when idle | Every 1s (50x then wait) | None until nudge timer |
| LLM calls when processing | Every 1s (counter-limited) | Every 1s while producing commands |
| Spam prevention | String dedup + prompt | Natural: LLM not called without new info |
| Autonomous exploration | Wake timer restores loop counter | Nudge timer activates agent |
| Multi-step chains | Counter-limited (50 max) | Command-driven + safety counter |

## What this removes
- `&prevresponse`, `$isdup`, `if $isdup` dedup branch
- `spamShield` config + declaration
- Unconditional loop decrement on every iteration
- `REMEMBER:OUTPUT_NOTHING_ELSE_THAN` forced command on non-command output
- `nextWakeAt` reset inside the active path

## What this preserves
- `maxNewInputLoops` (50) as safety ceiling
- `maxWakeLoops` (1) for nudge-triggered chain budget
- `wakeupInterval` (600s) for nudge frequency
- `sleepInterval` (1s) for poll frequency
- Aggressive goal-seeking prompt
- `&lastsend` channel-level send dedup
- Full command execution pipeline
- History and memory systems

## Verification

1. **Processing chain**: Send a message -> agent chains (query -> act -> send -> remember -> idle). Check `IDLE:` appears in logs after the chain.
2. **No spam**: After going idle, no LLM calls until nudge timer or new message. Verify with `CHARS_SENT:` log lines -- they should stop during idle periods.
3. **Nudge works**: Wait `wakeupInterval` -> agent activates, explores memory/goals, chains until done, goes idle again.
4. **Safety limit**: Set `maxNewInputLoops` low (e.g., 5), verify `SAFETY_LIMIT:` appears and agent goes idle.
5. **New message interrupts idle**: Agent is idle -> send message -> immediate activation, no waiting for nudge.
6. **Self-evolution**: Agent uses query, remember, pin, search, metta during nudge-triggered chains.


Completed

  - Removed spamShield and its declaration                                                
  - Added &busy state, removed unconditional loop decrement                                                                                                                                         
  - Nudge timer check in let* bindings                                                                                                                                                              
  - &busy gates LLM calls                                                                                                                                                                           
  - Empty commands → idle transition with nudge timer                                                                                                                                               
  - Safety limit → idle transition                                                                                                                                                                  
  - No more spam reprimand text or dedup logic                                                                                                                                                      
                                                                                                                                                                                                    
  Let me check for any remaining references to removed state.                                                                                                                                       
                                                                                                                                                                                                    
  Searched for 1 pattern (ctrl+o to expand)                                                                                                                                                       
                                                                                                                                                                                                    
● Clean — no stale references. The implementation is complete.                                                                                                                                    
                                                                                          
  Summary of changes to src/loop.metta:                                                                                                                                                             
                                                                                                                                                                                                    
  - Polling is now cheap: When &busy is False, the loop just checks for messages and the nudge timer — no LLM calls, no API cost.                                                                   
  - Processing is command-driven: The LLM chains as long as it produces commands. When it outputs nothing (empty $sexpr), the agent goes idle and sets a nudge timer.                               
  - Nudging replaces the old wake timer: When &busy has been False for wakeupInterval (600s), the agent reactivates with maxWakeLoops + 1 iterations to explore goals.                              
  - Safety counter (maxNewInputLoops = 50) still prevents infinite chains.                                                                                                                          
  - Removed: spamShield, &prevresponse, dedup logic, REMEMBER:OUTPUT_NOTHING_ELSE_THAN forced commands, the spam reprimand string.    



Here's the breakdown of the context sent to the LLM at each iteration. The full string is assembled in two stages:                                                                                
                                                                                                                                                                                                    
  Stage 1: getContext (line 25-33 of loop.metta)                                                                                                                                                    
                                                                                                                                                                                                    
  Builds the system-side string by concatenating these sections:                                                                                                                                    
                                                                                                                                                                                                    
  ┌─────────────────────────┬─────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────┐   
  │         Section         │                           Source                            │                                            How appended                                             │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ PROMPT:                 │ (getPrompt) → reads memory/prompt.txt from disk             │ Hardcoded in getContext. The system prompt — identity, goals, behavioral rules.                     │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │                         │                                                             │ Hardcoded in getContext. The tool catalog: remember, query, episodes, pin, shell, read-file,        │   
  │ SKILLS:                 │ (getSkills) → hardcoded list in src/skills.metta            │ write-file, append-file, send, search, tavily-search, technical-analysis, metta, plus NAL/PLN       │   
  │                         │                                                             │ examples.                                                                                           │   
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ OUTPUT_FORMAT:          │ Literal string in getContext                                │ Hardcoded. Tells the LLM to output up to 5 lines of toolName arg format.                            │
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ LAST_SKILL_USE_RESULTS: │ (last_chars (get-state &lastresults) (maxFeedback)) — the   │ Hardcoded in getContext. Contains the (RESULTS: ...) output from the previous iteration's command   │
  │                         │ &lastresults state atom, truncated to 50,000 chars          │ execution. Set by the loop after evaling the LLM's commands.                                        │   
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ HISTORY:                │ (getHistory) → reads memory/history.metta from disk,        │ Hardcoded in getContext. A persistent append-only log of timestamped episodes — human messages, LLM │   
  │                         │ truncated to last 30,000 chars                              │  responses, and errors. Written by addToHistory in memory.metta.                                    │   
  ├─────────────────────────┼─────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ TIME:                   │ (get_time_as_string) — current wall-clock time              │ Hardcoded in getContext.                                                                            │   
  └─────────────────────────┴─────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────┘   
   
  Stage 2: Loop body (line 62 of loop.metta)                                                                                                                                                        
                  
  ($send (py-str ($prompt :-:-:-: $lastmessage)))                                                                                                                                                   
   
  Concatenates getContext output + the delimiter :-:-:-: + the user-side message:                                                                                                                   
                  
  ┌──────────────┬───────────────────────────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────┐   
  │   Section    │                                    Source                                     │                                         How appended                                         │
  ├──────────────┼───────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ :-:-:-:      │ Literal delimiter                                                             │ Hardcoded in loop. Used by _chatAsiOne to split into system/user messages. For other         │
  │              │                                                                               │ providers, _chat replaces it with a space.                                                   │
  ├──────────────┼───────────────────────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤   
  │ $lastmessage │ (if $msgnew (HUMAN-MSG: $msg) "") — either the new human message prefixed     │ Hardcoded in loop. $msg comes from (get-state &prevmsg), which is set from (receive) — the   │   
  │              │ with HUMAN-MSG:, or empty string                                              │ channel adapter's latest message.                                                            │   
  └──────────────┴───────────────────────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────┘   
                  
  Summary: nothing is dynamic/agent-driven                                                                                                                                                          
   
  Every section is hardcoded in the getContext function or the loop body. The agent's skill calls don't modify what sections appear — they only affect the content of two sections:                 
                  
  - LAST_SKILL_USE_RESULTS: populated by evaluating whatever commands the LLM returned last iteration                                                                                               
  - HISTORY: grown by addToHistory after each iteration with commands
                                                                            

❯ Does the LLM have any way to know that the HUMAN-MSG appended to its context is a contemporaneous one from the user versus past message?                                                       
                      
The real gap: there's no concept of a "turn" or "conversation state" passed to the LLM. It doesn't know:                                                                                          
  - "You're on iteration 3 of 50 responding to this human message"
  - "You already replied to this message — now continue your autonomous work"                                                                                                                       
  - "This is a wake-up with no human trigger"                                
                                                                                                                                                                                                    
  Every iteration looks the same to the LLM: a flat context with prompt + skills + results + history + time + maybe a human message. It has to reconstruct what's going on from the history tail,   
  which is exactly the kind of reasoning LLMs are bad at doing reliably — hence the repetition loops in your log.  

  The HUMAN-MSG: label only appears when $msgnew is true — meaning the message is genuinely new this iteration. On continuation iterations, the LLM gets "". So in that narrow sense, the presence
  of HUMAN-MSG: does signal "this is fresh."
                                                                                                                                                                                                    
  The HISTORY: section contains timestamped episodes, and TIME: gives the current clock. In theory the LLM could compare the human message text against recent history entries to infer it already  
  responded — but that's fragile and nothing in the prompt guides it to do so.
                                                                                                                                                                                                    
  This is part of why the repetition loops happen in your log: the agent sees HUMAN-MSG: Matthew Behrend: Quick check in, are you stuck in any repetitive cycles? on the iteration it arrives,      
  responds, and then on subsequent wake-ups the message is gone (replaced by ""). But the history shows the exchange happened, and the LLM keeps re-engaging with the topic because nothing
  explicitly tells it "you already handled this input."                                                                                                                                             
                  
  The old spamShield was a blunt attempt to address this — sending " DO NOT RE-SEND OR SPAM!" on continuation iterations. The new state machine approach is better architecturally (don't call the  
  LLM when idle), but the LLM still has no explicit signal distinguishing "fresh human input" from "continuation with no new input" when it is called during busy iterations.
                                                                                                                                                                                                    
  A simple improvement would be to give the LLM an unambiguous signal without relying on prompt hacks.       
  
● Here are concrete improvements, ordered from simplest to most impactful:
         
  1. Add an iteration context tag (minimal change)                                                                                                                                                  
                         
  Replace the bare $lastmessage with a situational label. In loop.metta, the $lastmessage binding currently does:                                                                                   
                                                                                                                                                                                                    
  (if $msgnew (HUMAN-MSG: $msg) "")                                                                                                                                                                 
                                                                                                                                                                                                    
  Change to something like:                                                                                                                                                                         

  (if $msgnew
      (NEW-HUMAN-MSG: $msg)                                                                                                                                                                         
      (if (== (get-state &loops) (maxNewInputLoops))
          (WAKE-UP: no new input, autonomous iteration)                                                                                                                                             
          (CONTINUATION: iteration $loopsRemaining of $loopsTotal, no new input)))                                                                                                                  
                                                                                                                                                                                                    
  This gives the LLM three unambiguous signals:                                                                                                                                                     
  - NEW-HUMAN-MSG — respond to this person                                                                                                                                                          
  - WAKE-UP — you were idle, now check goals                                                                                                                                                        
  - CONTINUATION — you already started working, keep going or stop
                                                                                                                                                                                                    
  2. Track and expose the trigger reason                                                                                                                                                            
                                                                                                                                                                                                    
  Add a &triggerReason state atom set at the point where &busy transitions to True:                                                                                                                 
                  
  ; New human message arrived                                                                                                                                                                       
  (change-state! &triggerReason "new_human_message")
                                                                                                                                                                                                    
  ; Wake timer expired
  (change-state! &triggerReason "scheduled_wakeup")                                                                                                                                                 
                                                                                                                                                                                                    
  ; Continuation of existing work
  (change-state! &triggerReason "continuation")                                                                                                                                                     
                  
  Then include it in getContext:                                                                                                                                                                    
   
  " TRIGGER: " (get-state &triggerReason)                                                                                                                                                           
  " ITERATION: " (- (maxNewInputLoops) (get-state &loops)) " of " (maxNewInputLoops)
                                                                                                                                                                                                    
  This is cheap — one new state atom, a few characters in the context — and it eliminates all ambiguity about why the LLM is being called.                                                          
                                                                                                                                                                                                    
  3. Separate the "last human message" from the "current turn input"                                                                                                                                
                  
  Right now, &prevmsg serves double duty: it's both "the most recent message from a human" and "the input for this turn." These should be separate:                                                 
                  
  - &currentInput: set to the human message on the first iteration, then cleared to "" after that iteration. The LLM sees it once.                                                                  
  - &lastHumanMsg: persists across iterations for history/context, but is labeled as LAST-HUMAN-MSG-AT: <timestamp> so the LLM knows it's stale.
                                                                                                                                                                                                    
  This directly prevents the pattern where the LLM keeps re-engaging with an old message because it can't tell it already handled it.    
  
