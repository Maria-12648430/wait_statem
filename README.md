# wait_statem

`wait_statem:enter_wait/2` must be the last call in a state call.
It has not effect when it is not the last call, and it cannot be used in state enter calls.

`wait_statem:enter_wait/2` changes the callback module and performs a state change.
State and event timeouts are implicitly cancelled. Generic timeouts will keep running.

The arguments given to `gen_statem:enter_wait/2` must be the calling module and a map or property list of the options listed below.

## Options

* `callback := Fun :: (atom() | fun((State :: term(), StateData0 :: term()) -> ok | {ok, StateData1 :: term()} | retry | {retry, StateData1 :: term()} | error | {error, StateData1 :: term()})` (mandatory).

  The callback function to try and retry, either as the name of a function in the module given to `enter_wait/2` or an anonymous function. The arguments are the current state and data.
  * If the callback returns `ok` or an `ok` tuple, this is a success and the state machine transitions to the state given in the `success_state` option.
  * If `retry` or a `retry` tuple is returned, the callback is retried after the timeout defined by the `strategy` option. If the maximum number of attempts is exhausted, the state machine transitions to the state given in the `error_state` option.
  * If `error` or an `error` tuple is returned, this means giving up, and the state machine transitions to the state given in the `error_state` option.

* `strategy := {simple, StrategyOpts :: (map() | proplists:proplist())} | {custom, {Fun :: (atom() | fun((Attempt :: non_neg_integer(), State :: term(), StateData0 :: term()) -> {ok, Timeout :: non_neg_integer()} | {ok, Timeout :: non_neg_integer(), StateData1 :: term()} | error | {error, StateData1 :: term()})})` (mandatory)
  
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
    
  More advanced timeout strategies can be implemented by using the `custom` strategy, which takes a function that is given the current attempt, state and data as arguments.

* `timing => relative | absolute` (optional, default `relative`)

  Whether the calculated timeouts are to be related to the end of the previous attempt (`relative`) or to the start (`absolute`).

* `success_state => State :: term()` (optional, defaults to the state in which `enter_wait/1` was called)

  State to transition to after success.

* `error_state => term()` (optional, defaults to the state in which `enter_wait/1` was called)

  State to transition to when the maximum number of attempts is exhausted.
