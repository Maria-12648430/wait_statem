# wait_statem

`wait_statem:enter_wait/1` must be the last call in a state call.
It has not effect when it is not the last call, and it cannot be used in state enter calls.

`wait_statem:enter_wait/1` changes the callback module and performs a state change.
State and event timeouts are implicitly cancelled. Generic timeouts will keep running.

The argument given to `gen_statem:enter_wait/1` must be a map or property list of the following options.

## Options

* `callback => fun((StateData0 :: term()) -> {ok, StateData1 :: term()} | {retry, StateData1 :: term()}) | {stop, StateData1 :: term()}` (mandatory).
  
  The callback to try and retry.
  * If the callback returns an `ok` tuple, this is a success and the state machine transitions to the state given in the `success_state` option.
  * If a `retry` tuple is returned, the callback is retried after the timeout defined by the `strategy` option. If the maximum number of attempts is exhausted, the state machine transitions to the state given in the `error_state` option.
  * If a `stop` tuple is returned, this means giving up, and the state machine transitions to the state given in the `error_state` option.
  * If the callback crashes without returning anything, the state machine transitions to the state given in the `error_state` option.

* `callback_timeout => timeout()` (optional, default `infinity`)

  Maximum allowed time for the callback to execute. If the callback does not return within this time, it is killed and the state machine transitions to the state given in the `error_state` option.

* `strategy => {simple, StrategyOpts :: map()} | {custom, fun((Attempt :: non_neg_integer()) -> {ok, non_neg_integer()} | error)}` (mandatory)
  
  Strategy used to calculate timeouts between retrying the function given in the `callback` option.
  
  The built-in `simple` strategy takes a map with the following options:
  
  * `delay := non_neg_integer()` (optional, default `0`)
    
    Constant delay time in milliseconds.
    
  * `time := non_neg_integer()` (optional, default `0`)

    Backoff base time in milliseconds.
    
  * `backoff := number()` (optional, default `0`)

    Backoff exponent.
    
  * `jitter := non_neg_integer()` (optional, default `0`)

    Random value between `0` and the given value which will be added to the timeout.
    
  * `max := non_neg_integer() | infinity` (optional, default `infinity`)
  
    Maximum number of attempts.
    
  The time between attempts is calculated as follows: Delay + Attempt<sup>Backoff</sup> * Time + random(0.0 .. 1.0) * Jitter.
    
  More advanced timeout strategies can be implemented by using the `custom` strategy, which takes a function that is given the current attempt.

* `success_state := State :: term()` (optional, defaults to the state in which `enter_wait/1` was called)

  State to transition to after success.

* `error_state := term()` (optional, defaults to the state in which `enter_wait/1` was called)

  State to transition to when the maximum number of attempts is exhausted.

* `external_events := postpone | ignore | {reply_or_ignore, Reply :: term()}` (optional, default `postpone`)

  How to handle incoming external events (`{call, From}`, `cast` and `info`).
  
  * `postpone`

    Postpone external events and replay them after the transition to `success_state` or `error_state`.
    
  * `ignore`

    Discard all external events.
    
  * `{reply_or_ignore, Reply}`

    Reply to `call` events with the given `Reply`, ignore `cast` and `info` events

* `timeout_events := ignore | postpone` (optional, default `ignore`)
  
  How to handle generic timeout events. State and event timeouts were cancelled before.
  
  * `ignore`

    Discard all timeout events.
    
  * `postpone`

    Postpone timeout events and replay them after the transition to `success_state` or `error_state`.

