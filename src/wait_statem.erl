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
	opts,
	attempt=0,
	last_attempt,
	module,
	cb_mode,
	cur_state,
	return_data,
	postponed=[]
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
		next_state,
		{?MODULE, awake},
		#data{
			opts=normalize_opts(Opts, State),
			tag=Tag,
			attempt=0,
			module=Module,
			cb_mode=get_callback_mode(Module),
			cur_state=State,
			return_data=Data
		},
		[{next_event, internal, {Tag, sleep}}]
	};
handle_event(internal, {Tag, sleep}, {?MODULE, awake}, Data=#data{tag=Tag, opts=Opts}) ->
	BaseTime=case {Data#data.last_attempt, maps:get(timing, Opts)} of
		{undefined, _} ->
			erlang:monotonic_time(millisecond);
		{_, relative} ->
			erlang:monotonic_time(millisecond);
		{LastAttempt, absolue} ->
			LastAttempt
	end,
	case get_timeout(Data#data.module, maps:get(strategy, Opts), Data#data.attempt, Data#data.cur_state, Data#data.return_data) of
		error ->
			{
				next_state,
				{?MODULE, returning},
				Data,
				[{next_event, internal, {Tag, error}}]
			};
		{error, NewReturnData} ->
			{
				next_state,
				{?MODULE, returning},
				Data#data{
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, error}}]
			};
		{ok, Timeout} when is_integer(Timeout), Timeout>=0 ->
			{
				next_state,
				{?MODULE, sleeping},
				Data#data{
					attempt=Data#data.attempt+1
				},
				[{state_timeout, BaseTime+Timeout, {Tag, wakeup}, {abs, true}}]
			};
		{ok, Timeout, NewReturnData} when is_integer(Timeout), Timeout>=0 ->
			{
				next_state,
				{?MODULE, sleeping},
				Data#data{
					attempt=Data#data.attempt+1,
					return_data=NewReturnData
				},
				[{state_timeout, BaseTime+Timeout, {Tag, wakeup}, {abs, true}}]
			}
	end;
handle_event(state_timeout, {Tag, wakeup}, {?MODULE, sleeping}, Data=#data{tag=Tag, opts=Opts}) ->
	ExecTime=erlang:monotonic_time(millisecond),
	case execute_callback(Data#data.module, maps:get(callback, Opts), Data#data.cur_state, Data#data.return_data) of
		ok ->
			{
				next_state,
				{?MODULE, returning},
				Data,
				[{next_event, internal, {Tag, success}}]
			};
		{ok, NewReturnData} ->
			{
				next_state,
				{?MODULE, returning},
				Data#data{
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, success}}]
			};
		retry ->
			{
				next_state,
				{?MODULE, awake},
				Data#data{
					last_attempt=ExecTime
				},
				[{next_event, internal, {Tag, sleep}}]
			};
		{retry, NewReturnData} ->
			{
				next_state,
				{?MODULE, awake},
				Data#data{
					last_attempt=ExecTime,
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, sleep}}]
			};
		error ->
			{
				next_state,
				{?MODULE, returning},
				Data,
				[{next_event, internal, {Tag, error}}]
			};
		{error, NewReturnData} ->
			{
				next_state,
				{?MODULE, returning},
				Data#data{
					return_data=NewReturnData
				},
				[{next_event, internal, {Tag, error}}]
			}
	end;
handle_event(internal, {Tag, success}, {?MODULE, returning}, Data=#data{tag=Tag, opts=#{success_state:=SuccessState}}) ->
	{
		next_state,
		Data#data.cur_state,
		Data#data{postponed=[]},
		lists:reverse([{next_event, internal, {Tag, return, SuccessState}}|Data#data.postponed])
	};
handle_event(internal, {Tag, error}, {?MODULE, returning}, Data=#data{tag=Tag, opts=#{error_state:=ErrorState}}) ->
	{
		next_state,
		Data#data.cur_state,
		Data#data{postponed=[]},
		lists:reverse([{next_event, internal, {Tag, return, ErrorState}}|Data#data.postponed])
	};
handle_event(internal, {Tag, return, ReturnState}, CurState, Data=#data{tag=Tag, cur_state=CurState}) ->
	{
		next_state,
		ReturnState,
		Data#data.return_data,
		[pop_callback_module]
	};
handle_event(_Event, _Msg, CurState, #data{cur_state=CurState}) ->
	{
		keep_state_and_data,
		[postpone]
	};
handle_event(Type, Msg, State={?MODULE, _}, Data) ->
	handle_common_event(Type, Msg, State, Data).

handle_common_event(Type, Msg, {?MODULE, _}, Data) ->
	case execute_event(Data#data.cb_mode, Data#data.module, Type, Msg, Data#data.cur_state, Data#data.return_data) of
		keep_state_and_data ->
			keep_state_and_data;
		{keep_state_and_data, Actions} ->
			case validate_actions(Actions) of
				{true, Actions1} ->
					{
						keep_state,
						Data#data{
							postponed=[{next_event, Type, Msg}|Data#data.postponed]
						},
						Actions1
					};
				{false, Actions1} ->
					{
						keep_state_and_data,
						Actions1
					}
			end;
		{keep_state, NewReturnData} ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				}
			};
		{keep_state, NewReturnData, Actions} ->
			case validate_actions(Actions) of
				{true, Actions1} ->
					{
						keep_state,
						Data#data{
							return_data=NewReturnData,
							postponed=[{next_event, Type, Msg}|Data#data.postponed]
						},
						Actions1
					};
				{false, Actions1} ->
					{
						keep_state,
						Data#data{
							return_data=NewReturnData
						},
						Actions1
					}
			end;
		{next_state, NewState, NewReturnData} when NewState=:=Data#data.cur_state ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				}
			};
		{next_state, NewState, NewReturnData, Actions} when NewState=:=Data#data.cur_state ->
			case validate_actions(Actions) of
				{true, Actions1} ->
					{
						keep_state,
						Data#data{
							return_data=NewReturnData,
							postponed=[{next_event, Type, Msg}|Data#data.postponed]
						},
						Actions1
					};
				{false, Actions1} ->
					{
						keep_state,
						Data#data{
							return_data=NewReturnData
						},
						Actions1
					}
			end;
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

terminate(Reason, _State, Data=#data{module=Module}) ->
	Module:terminate(Reason, Data#data.cur_state, Data#data.return_data).

code_change(_OldVsn, State, Data, _Extra) ->
	{ok, State, Data}.

validate_actions(Actions0) when is_list(Actions0) ->
	{Postpone, Actions1}=lists:foldl(
		fun
			(postpone, {_, Acc}) ->
				{true, Acc};
			({postpone, Pp}, {_, Acc}) when is_boolean(Pp) ->
				{Pp, Acc};
			(Action, {PpAcc, Acc}) ->
				true=valid_action(Action),
				{PpAcc, [Action|Acc]}
		end,
		{false, []},
		Actions0
	),
	{Postpone, lists:reverse(Actions1)};
validate_actions(Action) ->
	validate_actions([Action]).

valid_action({next_event, _Event, _Content}) ->
	true;
valid_action({reply, _From, _Reply}) ->
	true;
valid_action(hibernate) ->
	true;
valid_action({hibernate, _Hibernate}) ->
	true;
valid_action({{timeout, _Name}, _TimeoutiOrUpdate, _Content}) ->
	true;
valid_action({{timeout, _Name}, _Timeout, _Content, _Options}) ->
	true;
valid_action({{timeout, _Name}, cancel}) ->
	true;
valid_action(_Action) ->
	false.

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
