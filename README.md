# wait_statem

`wait_statem:enter_wait/1` must be the last call in a state call.
It has not effect when it is not the last call, and it cannot be used in state enter calls.

`wait_statem:enter_wait/1` changes the callback module and performs a state change.
State and event timeouts are implicitly cancelled. Generic timeouts will keep running.

The argument given to `gen_statem:enter_wait/1` must be a map or property list of the following options.

## Options

* `callback := fun((StateData0 :: term()) -> ok | {ok, StateData1 :: term()} | retry | {retry, StateData1 :: term()} | stop | {stop, StateData1 :: term()})` (mandatory).
  
  The callback to try and retry.
  * If the callback returns `ok` or an `ok` tuple, this is a success and the state machine transitions to the state given in the `success_state` option.
  * If `retry` or a `retry` tuple is returned, the callback is retried after the timeout defined by the `strategy` option. If the maximum number of attempts is exhausted, the state machine transitions to the state given in the `error_state` option.
  * If `stop` or a `stop` tuple is returned, this means giving up, and the state machine transitions to the state given in the `error_state` option.
  * If the callback times out or crashes without returning anything, the state machine transitions to the state given in the `error_state` option.

* `callback_timeout => timeout()` (optional, default `infinity`)

  Maximum time for the execution of `callback`. If the callback does not return within this time, it is killed and the state machine transitions to the state given in the `error_state` option.

* `strategy := {simple, StrategyOpts :: (map() | proplists:proplist())} | {custom, fun((Attempt :: non_neg_integer()) -> {ok, Timeout :: non_neg_integer()} | error)}` (mandatory)
  
  Strategy used to calculate timeouts between retrying the function given in the `callback` option.
  
  The built-in `simple` strategy takes a map with the following options:
  
  * `delay => non_neg_integer()` (optional, default `0`)
    
    Constant delay time in milliseconds.
    
  * `time => non_neg_integer()` (optional, default `0`)

    Backoff base time in milliseconds.
    
  * `backoff => number()` (optional, default `0`)

    Backoff exponent.
    
  * `jitter => non_neg_integer()` (optional, default `0`)

    Random value between `0` and the given value which will be added to the timeout.
    
  * `max => non_neg_integer() | infinity` (optional, default `infinity`)
  
    Maximum number of attempts.
    
  The time between attempts is calculated as follows: delay + attempt<sup>backoff</sup> * time + random(0 .. jitter).
    
  More advanced timeout strategies can be implemented by using the `custom` strategy, which takes a function that is given the current attempt as single argument.

* `success_state => State :: term()` (optional, defaults to the state in which `enter_wait/1` was called)

  State to transition to after success.

* `error_state => term()` (optional, defaults to the state in which `enter_wait/1` was called)

  State to transition to when the maximum number of attempts is exhausted.

* `call_events => postpone | ignore | {reply, Reply :: term()} | Fun :: fun((Type :: {call, From :: gen_statem:from()}, Msg :: term(), Data0 :: term()) -> ignore | {ignore, Data1 :: term()} | postpone | {postpone, Data1 :: term()})` (optional, default `postpone`)

  `cast_events => postpone | ignore | Fun :: fun((Type :: cast, Msg :: term(), Data0 :: term()) -> ignore | {ignore, Data1 :: term()} | postpone | {postpone, Data1 :: term()})` (optional, default `postpone`)

  `info_events => postpone | ignore | Fun :: fun((Type :: info, Msg :: term(), Data0 :: term()) -> ignore | {ignore, Data1 :: term()} | postpone | {postpone, Data1 :: term()})` (optional, default `postpone`)

  `timeout_events => postpone | ignore | Fun :: fun((Type :: {timeout, Name :: term()}, Msg :: term(), Data0 :: term()) -> ignore | {ignore, Data1 :: term()} | postpone | {postpone, Data1 :: term()})` (optional, default `ignore`)

  How to handle any external and timeout events.
  
  * `postpone`

    Postpone events and replay them after the transition to `success_state` or `error_state`.
    
  * `ignore`

    Discard events.
    
  * `{reply, Reply}` (only available for `call_events`)

    Reply to call events with the given `Reply`.

  * `Fun`

    Call the given function with the event, message, and the current data as arguments. The function may return either `ignore` or `postpone`, resulting in the behavior described above, or `ignore` or `postpone` tuples with updated data. Note that the execution of this function has to be delayed if the `callback` is currently being executed, so consider using the static alternatives above which are always executed immediately.

* `external_events => postpone | ignore | {reply_or_ignore, Reply :: term()} | {reply_or_postpone, Reply :: term()} | Fun :: fun((Type :: ({call, From :: gen_statem:from()} | cast | info), Msg :: term(), Data0 :: term()) -> ignore | {ignore, Data1 :: term()} | postpone | {postpone, Data1 :: term()})` (optional, default `postpone`)

  Set handling of all external events (call, cast, info). If there exists a rule for a specific external event, it overrides this setting.

  * `{reply_or_ignore, Reply}`

    Reply to call events with the given `Reply` and discard other external events.

  * `{reply_or_postpone, Reply}`

    Reply to call events with the given `Reply` and postpone other external events.
