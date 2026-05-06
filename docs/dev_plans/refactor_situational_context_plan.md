# Plan: Add Situational Context to Agent Loop

## Context

The LLM has no way to distinguish why it's being called — new human message, continuation of a command chain, or scheduled wake-up. Every iteration looks identical: flat context + maybe a human message. This causes repetition loops where the LLM re-engages with stale topics, repeats commands, or fails to progress because it can't reconstruct its own state from 30K chars of history. (See the iteration 47 log for evidence: the agent repeated "I acknowledge the pattern" + `query "goals"` + `send` dozens of times.)

Five improvements address five distinct gaps. Implemented together in two files (`src/loop.metta`, `memory/prompt.txt`). No changes to `lib_llm_ext.py` — new context fields go system-side (before `:-:-:-:`), labeled `$lastmessage` goes user-side (after `:-:-:-:`).

---

## Improvement 1 — Expose trigger reason (`&triggerReason`)

**Problem:** The LLM cannot tell whether it was activated by a human message, a wake-up timer, or because its previous commands produced results. It has to guess from history, which it does badly — leading to responses like "Thanks for checking in" on autonomous wake-ups where no human is present.

### Step 1a: Init state atom in `initLoop` (`src/loop.metta` line 21-22 area)

```metta
(change-state! &triggerReason "boot")
```

### Step 1b: Set trigger at each `&busy` activation point

**New human message (lines 52-54):**
```metta
($_ (if (and (> $k 1) $msgnew)
        (progn (change-state! &busy True)
               (change-state! &triggerReason "new_human_message")
               (change-state! &loops (maxNewInputLoops))) _))
```

**Wake timer (lines 55-58):**
```metta
($_ (if (and (not (get-state &busy))
             (> (get_time) (get-state &nextWakeAt)))
        (progn (change-state! &busy True)
               (change-state! &triggerReason "scheduled_wakeup")
               (change-state! &loops (+ 1 (maxWakeLoops)))) _))
```

**After command execution (non-empty `$sexpr` branch, before loop decrement):**
```metta
(change-state! &triggerReason "continuation")
```

### Step 1c: Add to `getContext` (lines 25-33), after `TIME:`

```metta
" TRIGGER: " (get-state &triggerReason)
" ITERATION: " (- (maxNewInputLoops) (get-state &loops)) " of " (maxNewInputLoops)
```

`ITERATION` is bundled here because it's cheap and complements `TRIGGER` — together they tell the LLM "you're on iteration 12 of 50, continuing from previous commands."

---

## Improvement 2 — Label `$lastmessage` with situational tags

**Problem:** The LLM receives either `(HUMAN-MSG: ...)` or `""` after `:-:-:-:`. On continuation iterations it gets `""` with no indication of what it should be doing. On wake-ups it also gets `""` — indistinguishable from continuations. The old `spamShield` tried to fix this with `"DO NOT SPAM"` but that was a prompt hack, not a signal.

### Step 2: Replace `$lastmessage` construction (`src/loop.metta` line 60)

Replace:
```metta
($lastmessage (if $msgnew (HUMAN-MSG: $msg) ""))
```

With:
```metta
($lastmessage (if $msgnew
                  (NEW-HUMAN-MSG: $msg)
                  (if (== (get-state &triggerReason) "scheduled_wakeup")
                      "WAKE-UP: No new input. Check memory for goals and pursue them."
                      (if (== (get-state &triggerReason) "boot")
                          "BOOT: First iteration. Query memory for goals and begin."
                          ""))))
```

Labels:
- **`NEW-HUMAN-MSG:`** — respond to this person
- **`WAKE-UP:`** — check goals (first iteration of wake cycle only; subsequent iterations get `""` because step 1b sets triggerReason to `"continuation"` after execution)
- **`BOOT:`** — first iteration ever
- **`""`** — continuation; act on `LAST_SKILL_USE_RESULTS`

---

## Improvement 3 — Track last human message timestamp (`&lastHumanMsgTime`)

**Problem:** After the LLM responds to a human message and continues working autonomously, nothing tells it how long ago the human interaction happened. On wake-up 10 minutes later, the LLM may re-engage with the same topic because history entries don't carry obvious "this is old" signals. The LLM would need to parse timestamps from the history tail and compare to `TIME:` — unreliable reasoning it consistently fails at.

### Step 3a: Init in `initLoop`

```metta
(change-state! &lastHumanMsgTime "")
```

### Step 3b: Set when new message arrives (lines 52-54, same block as improvement 1b)

```metta
(change-state! &lastHumanMsgTime (get_time_as_string))
```

### Step 3c: Add to `getContext`, after `ITERATION:`

```metta
" LAST_HUMAN_MSG_AT: " (get-state &lastHumanMsgTime)
```

Now on a wake-up the LLM sees `LAST_HUMAN_MSG_AT: 2026-04-26 04:23:56` alongside `TIME: 2026-04-26 04:33:56` — a 10-minute gap that's trivially visible without parsing history.

---

## Improvement 4 — Rolling recent commands buffer (`&recentCommands`)

**Problem:** The LLM's only view of what it recently did is `LAST_SKILL_USE_RESULTS` (one iteration) and `HISTORY` (30K chars of timestamped episodes). Neither makes repetition patterns visible at a glance. In the log, the agent ran `query "goals"` + `send "I acknowledge the pattern..."` over a dozen consecutive times — but from the LLM's perspective each iteration looked fresh because the results were slightly different each time.

### Step 4a: Init in `initLoop`

```metta
(change-state! &recentCommands "")
```

### Step 4b: Update after command execution (non-empty `$sexpr` branch)

```metta
(change-state! &recentCommands
    (last_chars (py-str ((get-state &recentCommands) " || " (repr $sexpr))) 500))
```

Iterations separated by `||`. `last_chars` keeps ~500 chars — enough for ~5 iterations of commands. Old entries roll off naturally.

### Step 4c: Add to `getContext`, after `LAST_HUMAN_MSG_AT:`

```metta
" RECENT_COMMANDS: " (last_chars (get-state &recentCommands) 500)
```

### Step 4d: Clear on idle transitions

Both IDLE paths (empty response, line 83-86; safety limit, line 93-96) add:
```metta
(change-state! &recentCommands "")
```

Rationale for clearing: when the agent wakes up fresh, old command history from a previous activation is misleading — it would constrain the LLM's first move based on a stale context.

---

## Improvement 5 — Update prompt to reference new fields

**Problem:** The new context fields are useless if the prompt doesn't tell the LLM how to interpret them. Currently `memory/prompt.txt` says "never idle" and "never repeat" but gives no mechanism for the LLM to detect either condition.

### Step 5: Edit `memory/prompt.txt`

Add after the output format instructions:

```
Check TRIGGER to understand why you are being called:
- "new_human_message": A user sent a new message. Respond to it.
- "scheduled_wakeup": You were idle. Query memory for goals and act on them. Do not reference past human conversations.
- "continuation": You just executed commands. Review LAST_SKILL_USE_RESULTS and continue your work.
- "boot": First iteration. Query memory for existing goals.
Check RECENT_COMMANDS — if you see the same commands repeating, change direction. Try a different goal, a different query, or a new approach.
Check ITERATION to know how many iterations remain before the safety limit.
```

Update the existing "never idle" line (line 4) to:
```
When you have no immediate task, ALWAYS query memory for existing goals and act on them. If no goals exist, invent new ones. Never repeat the same commands — if a line of inquiry stalls, pivot to a different goal.
```

Remove "But never repeat the same commands or send the same message twice" — this is now enforced structurally via `RECENT_COMMANDS` visibility. The replacement wording above integrates the anti-repetition guidance with goal-seeking rather than framing idling as the escape hatch.

---

## Combined `initLoop` (final state)

```metta
(= (initLoop)
   (progn (configure maxNewInputLoops 50)
          (configure maxWakeLoops 1)
          (configure sleepInterval 1)
          (configure LLM gpt-5.4)
          (configure provider ASIOne)
          (configure maxOutputToken 6000)
          (configure reasoningMode medium)
          (configure wakeupInterval 600)
          (change-state! &prevmsg "")
          (change-state! &lastresults "")
          (change-state! &busy True)
          (change-state! &nextWakeAt (+ (get_time) (wakeupInterval)))
          (change-state! &triggerReason "boot")
          (change-state! &recentCommands "")
          (change-state! &lastHumanMsgTime "")
          (change-state! &loops (maxNewInputLoops))))
```

## Combined `getContext` (final state)

```metta
(= (getContext)
   (string-safe (py-str ("PROMPT: " (getPrompt) " SKILLS: " (getSkills)
                         " OUTPUT_FORMAT: Up to 5 lines, do not wrap quotes around args, do not use variables:" (newline)
                         " toolName1 arg1" (newline)
                         " toolName2 arg2" (newline)
                         " toolName3 arg3" (newline)
                         " toolName4 arg4" (newline)
                         " toolName5 arg5" (newline)
                         " LAST_SKILL_USE_RESULTS: " (last_chars (get-state &lastresults) (maxFeedback))
                         " HISTORY: " (getHistory)
                         " TIME: " (get_time_as_string)
                         " TRIGGER: " (get-state &triggerReason)
                         " ITERATION: " (- (maxNewInputLoops) (get-state &loops)) " of " (maxNewInputLoops)
                         " LAST_HUMAN_MSG_AT: " (get-state &lastHumanMsgTime)
                         " RECENT_COMMANDS: " (last_chars (get-state &recentCommands) 500)))))
```

## Combined non-empty `$sexpr` execution branch (final state)

```metta
(let* (($results (RESULTS: (collapse (let $s (superpose $sexpr) (COMMAND_RETURN: ($s (HandleError SINGLE_COMMAND_FORMAT_ERROR_NOTHING_WAS_DONE_PLEASE_FIX_AND_RETRY $s (catch (let $R (eval $s) (py-call (helper.normalize_string $R)))))))))))
       ($_ (println! $results)))
      (progn (if (or $msgnew (not (== $sexpr ()))) (addToHistory $msg $response $sexpr $msgnew) _)
             (change-state! &lastresults (string-safe (repr $results)))
             (change-state! &recentCommands
                 (last_chars (py-str ((get-state &recentCommands) " || " (repr $sexpr))) 500))
             (change-state! &triggerReason "continuation")
             (change-state! &loops (- (get-state &loops) 1))))
```

---

## Verification

1. **New message**: Send a message → log shows `TRIGGER: new_human_message`, `$lastmessage` is `NEW-HUMAN-MSG: <text>`. Next iteration: `TRIGGER: continuation`, `$lastmessage` is `""`.

2. **Wake-up**: Wait `wakeupInterval` → `TRIGGER: scheduled_wakeup`, `$lastmessage` is `WAKE-UP: ...`. Next iteration: `TRIGGER: continuation`.

3. **Repetition guard**: After several iterations, `RECENT_COMMANDS` shows the rolling buffer. Repeated patterns like `query "goals" || query "goals" || query "goals"` are visible in context.

4. **Stale message detection**: `LAST_HUMAN_MSG_AT` persists. On wake-up 10 min later, gap between `LAST_HUMAN_MSG_AT` and `TIME` is obvious.

5. **Safety limit**: Set `maxNewInputLoops` low → `SAFETY_LIMIT:` in logs, all buffers cleared.

6. **Token budget**: ~600 chars worst case. Negligible against 47K total context.
