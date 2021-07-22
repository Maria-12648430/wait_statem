-module(wait_statem).
-behaviour(gen_statem).

-export([enter_wait/2]).
-export([callback_mode/0]).
-export([init/1]).
-export([handle_event/4]).
-export([terminate/3]).
-export([code_change/4]).

-record(data, {
	tag,
	state,
	opts,
	attempt=0,
	last_attempt,
	module,
	cb_mode,
	return_data
}).

get_callback_mode(Module) ->
	get_callback_mode(Module:callback_mode(), undefined).

get_callback_mode([Mode=state_functions|T], _) ->
	get_callback_mode(T, Mode);
get_callback_mode([Mode=handle_event_function|T], _) ->
	get_callback_mode(T, Mode);
get_callback_mode([_|T], Mode) ->
	get_callback_mode(T, Mode);
get_callback_mode(Mode=state_functions, _) ->
	Mode;
get_callback_mode(Mode=handle_event_function, _) ->
	Mode;
get_callback_mode(_, Mode) when Mode=/=undefined ->
	Mode.

enter_wait(Module, Opts) ->
	{
		keep_state_and_data,
		[
			{push_callback_module, ?MODULE},
			{next_event, internal, {init, Module, Opts}}
		]
	}.

callback_mode() ->
	handle_event_function.

-spec init(_) -> no_return().
init(Args) ->
	erlang:error(not_implemented, [Args]).

handle_event(internal, {init, Module, Opts}, State, Data) ->
	Tag=make_ref(),
	{
		keep_state,
		#data{
			tag=Tag,
			state=awake,
			opts=normalize_opts(Opts, State),
			attempt=0,
			module=Module,
			cb_mode=get_callback_mode(Module),
			return_data=Data
		},
		[{next_event, internal, {Tag, sleep}}]
	};
handle_event(internal, {Tag, sleep}, State, Data=#data{tag=Tag, state=awake, opts=Opts}) ->
	case get_timeout(Data#data.module, maps:get(strategy, Opts), Data#data.attempt, State, Data#data.return_data) of
		error ->
			{
				keep_state,
				Data#data{
					state=returning
				},
				[{next_event, internal, {Tag, error}}]
			};
		{error, NewReturnData} ->
			{
				keep_state,
				Data#data{
					state=returning,
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, error}}]
			};
		{ok, Timeout} when is_integer(Timeout), Timeout>=0 ->
			{
				keep_state,
				Data#data{
					state=sleeping,
					attempt=Data#data.attempt+1
				},
				[{{timeout, {Tag, sleeping}}, get_basetime(Data#data.last_attempt, maps:get(timing, Opts))+Timeout, {Tag, wakeup}, {abs, true}}]
			};
		{ok, Timeout, NewReturnData} when is_integer(Timeout), Timeout>=0 ->
			{
				keep_state,
				Data#data{
					state=sleeping,
					attempt=Data#data.attempt+1,
					return_data=NewReturnData
				},
				[{{timeout, {Tag, sleeping}}, get_basetime(Data#data.last_attempt, maps:get(timing, Opts))+Timeout, {Tag, wakeup}, {abs, true}}]
			}
	end;
handle_event({timeout, {Tag, sleeping}}, {Tag, wakeup}, State, Data=#data{tag=Tag, state=sleeping, opts=Opts}) ->
	ExecTime=erlang:monotonic_time(millisecond),
	case execute_callback(Data#data.module, maps:get(callback, Opts), State, Data#data.return_data) of
		ok ->
			{
				keep_state,
				Data#data{
					state=returning
				},
				[{next_event, internal, {Tag, success}}]
			};
		{ok, NewReturnData} ->
			{
				keep_state,
				Data#data{
					state=returning,
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, success}}]
			};
		retry ->
			{
				keep_state,
				Data#data{
					state=awake,
					last_attempt=ExecTime
				},
				[{next_event, internal, {Tag, sleep}}]
			};
		{retry, NewReturnData} ->
			{
				keep_state,
				Data#data{
					state=awake,
					last_attempt=ExecTime,
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, sleep}}]
			};
		error ->
			{
				keep_state,
				Data#data{
					state=returning
				},
				[{next_event, internal, {Tag, error}}]
			};
		{error, NewReturnData} ->
			{
				keep_state,
				Data#data{
					state=returning,
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, error}}]
			}
	end;
handle_event(internal, {Tag, success}, _State, Data=#data{tag=Tag, state=returning, opts=#{success_state:=SuccessState}}) ->
	{
		next_state,
		SuccessState,
		Data#data.return_data,
		[{{timeout, Tag}, cancel}, pop_callback_module]
	};
handle_event(internal, {Tag, error}, _State, Data=#data{tag=Tag, opts=#{error_state:=ErrorState}}) ->
	{
		next_state,
		ErrorState,
		Data#data.return_data,
		[{{timeout, Tag}, cancel}, pop_callback_module]
	};
handle_event({timeout, {Tag, event}}, Msg, _State, #data{tag=Tag}) ->
	{
		keep_state_and_data,
		[{next_event, timeout, Msg}]
	};
handle_event(Type, Msg, State, Data) ->
	handle_common_event(Type, Msg, State, Data).

handle_common_event(Type, Msg, State, Data=#data{tag=Tag}) ->
	EvtTimerCancel={{timeout, {Tag, event}}, cancel},
	case execute_event(Data#data.cb_mode, Data#data.module, Type, Msg, State, Data#data.return_data) of
		keep_state_and_data ->
			keep_state_and_data;
		{keep_state_and_data, Actions} ->
			{
				keep_state_and_data,
				[EvtTimerCancel|validate_actions(Actions, Tag)]
			};
		{keep_state, NewReturnData} ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				},
				[EvtTimerCancel]
			};
		{keep_state, NewReturnData, Actions} ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				},
				[EvtTimerCancel|validate_actions(Actions, Tag)]
			};
		{next_state, State, NewReturnData} ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				},
				[EvtTimerCancel]
			};
		{next_state, State, NewReturnData, Actions} ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				},
				[EvtTimerCancel|validate_actions(Actions, Tag)]
			};
		{next_state, NewState, NewReturnData} ->
			{
				next_state,
				NewState,
				NewReturnData,
				[{{timeout, {Tag, sleeping}}, cancel}, EvtTimerCancel, pop_callback_module]
			};
		{next_state, NewState, NewReturnData, Actions} ->
			{
				next_state,
				NewState,
				NewReturnData,
				[{{timeout, Tag}, cancel}, EvtTimerCancel, pop_callback_module|Actions]
			};
		stop ->
			stop;
		{stop, Reason} ->
			{
				stop,
				Reason
			};
		{stop, Reason, NewReturnData} ->
			{
				stop,
				Reason,
				Data#data{
					return_data=NewReturnData
				}
			};
		{stop_and_reply, Reason, Replies} ->
			{
				stop_and_reply,
				Reason,
				Replies
			};
		{stop_and_reply, Reason, Replies, NewReturnData} ->
			{
				stop_and_reply,
				Reason,
				Replies,
				Data#data{
					return_data=NewReturnData
				}
			}
	end.

terminate(Reason, State, Data=#data{module=Module}) ->
	Module:terminate(Reason, State, Data#data.return_data).

code_change(_OldVsn, State, Data, _Extra) ->
	{ok, State, Data}.

get_basetime(undefined, _Timing) ->
	erlang:monotonic_time(millisecond);
get_basetime(_LastAttempt, relative) ->
	erlang:monotonic_time(millisecond);
get_basetime(LastAttempt, absolute) ->
	LastAttempt.

validate_actions(Actions, Tag) when is_list(Actions) ->
	lists:map(
		fun
			(A=postpone) -> A;
			(A={postpone, _}) -> A;
			(A={next_event, _, _}) -> A;
			(A={reply, _, _}) -> A;
			(A=hibernate) -> A;
			(A={hibernate, _}) -> A;
			(A={state_timeout, _}) -> A;
			(A={state_timeout, _, _}) -> A;
			(A={state_timeout, _, _, _}) -> A;
			(A={{timeout, _}, _}) -> A;
			(A={{timeout, _}, _, _}) -> A;
			(A={{timeout, _}, _, _, _}) -> A;
			({timeout, cancel}) -> {{timeout, {Tag, event}}, cancel};
			({timeout, TimeOrUpdate, Content}) -> {{timeout, {Tag, event}}, TimeOrUpdate, Content};
			({timeout, Time, Content, Opts}) -> {{timeout, {Tag, event}}, Time, Content, Opts};
			(Time) when is_integer(Time); Time=:=infinity -> {{timeout, {Tag, event}}, Time, Time}
		end,
		Actions
	);
validate_actions(Action, Tag) ->
	validate_actions([Action], Tag).

execute_callback(Module, Fun, State, Data) when is_atom(Fun) ->
	Module:Fun(State, Data);
execute_callback(_Module, Fun, State, Data) when is_function(Fun, 2) ->
	Fun(State, Data).

execute_event(state_functions, Module, Event, Msg, State, Data) ->
	Module:State(Event, Msg, Data);
execute_event(handle_event_function, Module, Event, Msg, State, Data) ->
	Module:handle_event(Event, Msg, State, Data).

get_timeout(_Module, {simple, #{max:=Max}}, N, _State, _Data) when is_integer(Max), N>=Max ->
	error;
get_timeout(_Module, {simple, #{delay:=Delay, time:=Time, backoff:=Backoff, jitter:=Jitter}}, N, _State, _Data) ->
	{ok, max(0, Delay + round(calc_backoff(N, Time, Backoff) + calc_jitter(Jitter)))};
get_timeout(Module, {custom, Fun}, N, State, Data) when is_atom(Fun) ->
	Module:Fun(N, State, Data);
get_timeout(_Module, {custom, Fun}, N, State, Data) when is_function(Fun, 3) ->
	Fun(N, State, Data).

calc_backoff(0, _T, _B) ->
	0;
calc_backoff(_N, 0, _B) ->
	0;
calc_backoff(_N, T, B) when B==0 ->
	T;
calc_backoff(N, T, B) when B==1 ->
	N * T;
calc_backoff(N, T, B) ->
	math:pow(N, B) * T.

calc_jitter(0) ->
	0;
calc_jitter(J) ->
	rand:uniform() * J.

normalize_opts(Opts, State) when is_map(Opts) ->
	normalize_opts1(Opts, State);
normalize_opts(Opts, State) when is_list(Opts) ->
	normalize_opts1(proplists:to_map(Opts), State).

normalize_opts1(Opts, _) when not is_map_key(callback, Opts) ->
	error(missing_callback);
normalize_opts1(Opts, _) when not is_map_key(strategy, Opts) ->
	error(missing_strategy);
normalize_opts1(Opts0, State) ->
	Opts1=#{
		callback => maps:get(callback, Opts0),
		strategy => maps:get(strategy, Opts0),
		timing => maps:get(timing, Opts0, relative),
		success_state => maps:get(success_state, Opts0, State),
		error_state => maps:get(error_state, Opts0, State)
	},
	maps:map(
		fun
			(callback, Fun) when is_atom(Fun) ->
				Fun;
			(callback, Fun) when is_function(Fun, 3) ->
				Fun;
			(strategy, {simple, StrategyOpts}) when is_map(StrategyOpts); is_list(StrategyOpts) ->
				{simple, normalize_strategy_opts(StrategyOpts)};
			(strategy, Strategy={custom, Fun}) when is_atom(Fun) ->
				Strategy;
			(strategy, Strategy={custom, Fun}) when is_function(Fun, 3) ->
				Strategy;
			(timing, Timing=relative) ->
				Timing;
			(timing, Timing=absolute) ->
				Timing;
			(success_state, SuccessState) ->
				SuccessState;
			(error_state, ErrorState) ->
				ErrorState;
			(K, V) ->
				error({invalid_option, {K, V}})
		end,
		Opts1
	).

normalize_strategy_opts(Opts) when is_map(Opts) ->
	normalize_strategy_opts1(Opts);
normalize_strategy_opts(Opts) when is_list(Opts) ->
	normalize_strategy_opts1(proplists:to_map(Opts)).

normalize_strategy_opts1(Opts0) ->
	Opts1=#{
		max => maps:get(max, Opts0, infinity),
		delay => maps:get(delay, Opts0, 0),
		time => maps:get(time, Opts0, 0),
		backoff => maps:get(backoff, Opts0, 0),
		jitter => maps:get(jitter, Opts0, 0)
	},
	maps:map(
		fun
			(max, infinity) ->
				infinity;
			(max, Max) when is_integer(Max), Max>=0 ->
				Max;
			(delay, Delay) when is_integer(Delay), Delay>=0 ->
				Delay;
			(time, Time) when is_integer(Time), Time>=0 ->
				Time;
			(backoff, Backoff) when is_number(Backoff) ->
				Backoff;
			(jitter, Jitter) when is_integer(Jitter) ->
				Jitter;
			(K, V) ->
				error({invalid_strategy_option, {K, V}})
		end,
		Opts1
	).
