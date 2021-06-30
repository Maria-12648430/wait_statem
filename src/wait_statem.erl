-module(wait_statem).
-behaviour(gen_statem).

-export([enter_wait/1]).
-export([callback_mode/0]).
-export([init/1]).
-export([handle_event/4]).
-export([code_change/4]).

-record(data, {
	opts,
	attempt=0,
	return_data,
	postponed=[]
}).

enter_wait(Opts) ->
	{
		keep_state_and_data,
		[
			{push_callback_module, ?MODULE},
			{next_event, internal, {init, Opts}}
		]
	}.

callback_mode() ->
	handle_event_function.

-spec init(_) -> no_return().
init(Args) ->
	erlang:error(not_implemented, [Args]).

handle_event(internal, {init, Opts}, State, Data) ->
	{
		next_state,
		{?MODULE, undefined},
		#data{
			opts=normalize_opts(Opts, State),
			attempt=0,
			return_data=Data
		},
		[{next_event, internal, sleep}]
	};
handle_event(internal, sleep, {?MODULE, undefined}, Data=#data{opts=Opts}) ->
	case get_timeout(Data#data.attempt, maps:get(strategy, Opts)) of
		error ->
			{
				next_state,
				{?MODULE, error},
				Data,
				[{next_event, internal, return}]
			};
		{ok, Timeout} ->
			{
				next_state,
				{?MODULE, sleeping},
				Data#data{
					attempt=Data#data.attempt+1
				},
				[{state_timeout, Timeout, wakeup}]
			}
	end;
handle_event(state_timeout, wakeup, {?MODULE, sleeping}, Data=#data{opts=Opts}) ->
	Callback=maps:get(callback, Opts),
	CallbackTimeout=maps:get(callback_timeout, Opts),
	Self=self(),
	Tag=make_ref(),
	{Pid, Mon}=spawn_monitor(fun () -> Self ! {Tag, Callback(Data#data.return_data)} end),
	{
		next_state,
		{?MODULE, {executing, Tag, Pid, Mon}},
		Data,
		[{state_timeout, CallbackTimeout, timeout}]
	};
handle_event(state_timeout, timeout, {?MODULE, {executing, _Tag, Pid, _Mon}}, _Data) ->
	exit(Pid, kill),
	keep_state_and_data;
handle_event(info, {Tag, Result}, {?MODULE, {executing, Tag, _Pid, Mon}}, Data) ->
	demonitor(Mon, [flush]),
	case Result of
		ok ->
			{
				next_state,
				{?MODULE, success},
				Data,
				[{next_event, internal, return}]
			};
		{ok, NewReturnData} ->
			{
				next_state,
				{?MODULE, success},
				Data#data{
					return_data=NewReturnData
				},
				[{next_event, internal, return}]
			};
		retry ->
			{
				next_state,
				{?MODULE, undefined},
				Data,
				[{next_event, internal, sleep}]
			};
		{retry, NewReturnData} ->
			{
				next_state,
				{?MODULE, undefined},
				Data#data{
					return_data=NewReturnData
				},
				[{next_event, internal, sleep}]
			};
		stop ->
			{
				next_state,
				{?MODULE, error},
				Data,
				[{next_event, internal, return}]
			};
		{stop, NewReturnData} ->
			{
				next_state,
				{?MODULE, error},
				Data#data{
					return_data=NewReturnData
				},
				[{next_event, internal, return}]
			}
	end;
handle_event(info, {'DOWN', Mon, process, Pid, _Reason}, {?MODULE, {executing, _Tag, Pid, Mon}}, Data=#data{opts=Opts}) ->
	{
		next_state,
		maps:get(error_state, Opts),
		Data#data.return_data,
		[pop_callback_module|lists:reverse(Data#data.postponed)]
	};
handle_event(internal, return, {?MODULE, success}, Data=#data{opts=#{success_state:=ReturnState}}) ->
	{
		next_state,
		ReturnState,
		Data#data.return_data,
		[pop_callback_module|lists:reverse(Data#data.postponed)]
	};
handle_event(internal, return, {?MODULE, error}, Data=#data{opts=#{error_state:=ReturnState}}) ->
	{
		next_state,
		ReturnState,
		Data#data.return_data,
		[pop_callback_module|lists:reverse(Data#data.postponed)]
	};
handle_event(Type={call, _From}, Msg, State={?MODULE, _}, Data=#data{opts=#{call_events:=How}}) ->
	handle_common_event(How, Type, Msg, State, Data);
handle_event(Type=cast, Msg, State={?MODULE, _}, Data=#data{opts=#{cast_events:=How}}) ->
	handle_common_event(How, Type, Msg, State, Data);
handle_event(Type=info, Msg, State={?MODULE, _}, Data=#data{opts=#{info_events:=How}}) ->
	handle_common_event(How, Type, Msg, State, Data);
handle_event(Type={timeout, _Name}, Msg, State={?MODULE, _}, Data=#data{opts=#{timeout_events:=How}}) ->
	handle_common_event(How, Type, Msg, State, Data);
handle_event(_Type, _Msg, _State, _Data) ->
	keep_state_and_data.

handle_common_event(ignore, _Type, _Msg, {?MODULE, _}, _Data) ->
	keep_state_and_data;
handle_common_event(postpone, Type, Msg, {?MODULE, _}, Data) ->
	{
		keep_state,
		Data#data{
			postponed=[{next_event, Type, Msg}|Data#data.postponed]
		}
	};
handle_common_event({reply, Reply}, {call, From}, _Msg, {?MODULE, _}, _Data) ->
	{
		keep_state_and_data,
		[{reply, From, Reply}]
	};
handle_common_event(Fun, _Type, _Msg, {?MODULE, {executing, _, _, _}}, _Data) when is_function(Fun, 3) ->
	{
		keep_state_and_data,
		[postpone]
	};
handle_common_event(Fun, Type, Msg, {?MODULE, _}, Data) when is_function(Fun, 3) ->
	case Fun(Type, Msg, Data#data.return_data) of
		ignore ->
			keep_state_and_data;
		{ignore, NewReturnData} ->
			{
				keep_state,
				Data#data{
					return_data=NewReturnData
				}
			};
		postpone ->
			{
				keep_state,
				Data#data{
					postponed=[{next_event, Type, Msg}|Data#data.postponed]
				}
			};
		{postpone, NewReturnData} ->
			{
				keep_state,
				Data#data{
					postponed=[{next_event, Type, Msg}|Data#data.postponed],
					return_data=NewReturnData
				}
			}
	end.

code_change(_OldVsn, State, Data, _Extra) ->
	{ok, State, Data}.

get_timeout(N, {simple, #{max:=Max}}) when is_integer(Max), N>=Max ->
	error;
get_timeout(N, {simple, #{delay:=Delay, time:=Time, backoff:=Backoff, jitter:=Jitter}}) ->
	{ok, Delay + round(calc_backoff(N, Time, Backoff) + calc_jitter(Jitter))};
get_timeout(N, {custom, Fun}) ->
	Fun(N).

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
		callback_timeout => maps:get(callback_timeout, Opts0, infinity),
		call_events => maps:get(call_events, Opts0, maps:get(external_events, Opts0, postpone)),
		cast_events => maps:get(cast_events, Opts0, maps:get(external_events, Opts0, postpone)),
		info_events => maps:get(info_events, Opts0, maps:get(external_events, Opts0, postpone)),
		timeout_events => maps:get(timeout_events, Opts0, ignore),
		success_state => maps:get(success_state, Opts0, State),
		error_state => maps:get(error_state, Opts0, State)
	},
	maps:map(
		fun
			(callback, Callback) when is_function(Callback, 1) ->
				Callback;
			(strategy, {simple, StrategyOpts}) when is_map(StrategyOpts); is_list(StrategyOpts) ->
				{simple, normalize_strategy_opts(StrategyOpts)};
			(strategy, Strategy={custom, Fun}) when is_function(Fun, 1) ->
				Strategy;
			(callback_timeout, infinity) ->
				infinity;
			(callback_timeout, Timeout) when is_integer(Timeout), Timeout>=0 ->
				Timeout;
			(call_events, postpone) ->
				postpone;
			(call_events, ignore) ->
				ignore;
			(call_events, CallEvents={reply, _Reply}) ->
				CallEvents;
			(call_events, {reply_or_postpone, Reply}) ->
				{reply, Reply};
			(call_events, {reply_or_ignore, Reply}) ->
				{reply, Reply};
			(call_events, Fun) when is_function(Fun, 3) ->
				Fun;
			(cast_events, postpone) ->
				postpone;
			(cast_events, ignore) ->
				ignore;
			(cast_events, {reply_or_postpone, _Reply}) ->
				postpone;
			(cast_events, {reply_or_ignore, _Reply}) ->
				ignore;
			(cast_events, Fun) when is_function(Fun, 3) ->
				Fun;
			(info_events, postpone) ->
				postpone;
			(info_events, ignore) ->
				ignore;
			(info_events, {reply_or_postpone, _Reply}) ->
				postpone;
			(info_events, {reply_or_ignore, _Reply}) ->
				ignore;
			(info_events, Fun) when is_function(Fun, 3) ->
				Fun;
			(timeout_events, ignore) ->
				ignore;
			(timeout_events, postpone) ->
				postpone;
			(timeout_events, Fun) when is_function(Fun, 3) ->
				Fun;
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
