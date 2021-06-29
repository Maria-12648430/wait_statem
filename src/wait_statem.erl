-module(wait_statem).
-behaviour(gen_statem).

-export([enter_wait/1]).
-export([callback_mode/0]).
-export([init/1]).
-export([handle_event/4]).
-export([code_change/4]).

-record(data, {
	ref,
	opts,
	timer,
	attempt,
	return_data
}).

enter_wait(Opts) when is_map(Opts) ->
	{
		keep_state_and_data,
		[
			{push_callback_module, ?MODULE},
			{next_event, internal, {init, Opts}}
		]
	};
enter_wait(Opts) ->
	enter_wait(proplists:to_map(Opts)).

callback_mode() ->
	handle_event_function.

init(Args) ->
	erlang:error(not_implemented, [Args]).

handle_event(internal, {init, Opts}, State, Data) ->
	Ref=make_ref(),
	{
		next_state,
		{?MODULE, Ref},
		#data{
			ref=Ref,
			opts=normalize_opts(Opts, State),
			attempt=0,
			return_data=Data
		},
		[{next_event, internal, sleep}]
	};
handle_event(internal, sleep, {?MODULE, Ref}, Data=#data{ref=Ref, opts=Opts}) ->
	case get_timeout(Data#data.attempt, maps:get(strategy, Opts)) of
		error ->
			{
				next_state,
				maps:get(error_state, Opts),
				Data#data.return_data,
				[pop_callback_module]
			};
		{ok, Timeout} ->
			Timer=erlang:start_timer(Timeout, self(), wakeup),
			{
				keep_state,
				Data#data{
					timer=Timer,
					attempt=Data#data.attempt+1
				}
			}
	end;
handle_event(info, {timeout, Timer0, wakeup}, {?MODULE, Ref}, Data=#data{ref=Ref, opts=Opts, timer=Timer0}) ->
	Callback=maps:get(callback, Opts),
	CallbackTimeout=maps:get(callback_timeout, Opts),
	Self=self(),
	Tag=make_ref(),
	{Pid, Mon}=spawn_monitor(fun () -> Self ! {Tag, Callback(Data#data.return_data)} end),
	Result=receive
		{Tag, Result1} ->
			demonitor(Mon, [flush]),
			Result1;
		{'DOWN', Mon, process, Pid, _Reason} ->
			{retry, Data#data.return_data}
	after CallbackTimeout ->
		exit(Pid, kill),
		receive
			{Tag, Result1} ->
				demonitor(Mon, [flush]),
				Result1;
			{'DOWN', Mon, process, Pid, _Reason} ->
				{retry, Data#data.return_data}
		end
	end,
	case Result of
		{ok, NewReturnData} ->
			{
				next_state,
				maps:get(success_state, Opts),
				NewReturnData,
				[pop_callback_module]
			};
		{retry, NewReturnData} ->
			{
				keep_state,
				Data#data{
					timer=undefined,
					return_data=NewReturnData
				},
				[{next_event, internal, sleep}]
			};
		{stop, NewReturnData} ->
			{
				next_state,
				maps:get(error_state, Opts),
				NewReturnData,
				[pop_callback_module]
			}
	end;
handle_event({call, _From}, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:=ignore}}) ->
	keep_state_and_data;
handle_event({call, _From}, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:=postpone}}) ->
	{keep_state_and_data, [postpone]};
handle_event({call, From}, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:={reply_or_ignore, Reply}}}) ->
	{keep_state_and_data, [{reply, From, Reply}]};
handle_event(cast, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:=ignore}}) ->
	keep_state_and_data;
handle_event(cast, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:=postpone}}) ->
	{keep_state_and_data, [postpone]};
handle_event(cast, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:={reply_or_ignore, _Reply}}}) ->
	keep_state_and_data;
handle_event(info, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:=ignore}}) ->
	keep_state_and_data;
handle_event(info, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:=postpone}}) ->
	{keep_state_and_data, [postpone]};
handle_event(info, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{external_events:={reply_or_ignore, _Reply}}}) ->
	keep_state_and_data;
handle_event({timeout, _Name}, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{timeout_events:=ignore}}) ->
	keep_state_and_data;
handle_event({timeout, _Name}, _Msg, {?MODULE, Ref}, #data{ref=Ref, opts=#{timeout_events:=postpone}}) ->
	{keep_state_and_data, [postpone]};
handle_event(_Type, _Msg, _State, _Data) ->
	keep_state_and_data.

code_change(_OldVsn, State, Data, _Extra) ->
	{ok, State, Data}.

get_timeout(N, {simple, #{max:=Max}}) when is_integer(Max), N>=Max ->
	error;
get_timeout(N, {simple, #{delay:=Delay, time:=Time, backoff:=Backoff, jitter:=Jitter}}) ->
	{ok, calc_timeout(N, Delay, Time, Backoff, Jitter)};
get_timeout(N, {custom, Fun}) ->
	Fun(N).

calc_timeout(0, D, _, _, 0) ->
	D;
calc_timeout(_, D, 0, _, 0) ->
	D;
calc_timeout(0, D, _, _, J) ->
	D + round(rand:uniform() * J);
calc_timeout(_, D, 0, _, J) ->
	D + round(rand:uniform() * J);
calc_timeout(_, D, T, B, 0) when B==0 ->
	D + T;
calc_timeout(_, D, T, B, J) when B==0 ->
	D + T + round(rand:uniform() * J);
calc_timeout(N, D, T, B, 0) when B==1 ->
	D + (N * T);
calc_timeout(N, D, T, B, J) when B==1 ->
	D + (N * T) + round(rand:uniform() * J);
calc_timeout(N, D, T, B, J) ->
	D + round(math:pow(N, B) * T + rand:uniform() * J).

normalize_opts(Opts, State) when is_map(Opts) ->
	normalize_opts1(Opts, State);
normalize_opts(Opts, State) when is_list(Opts) ->
	normalize_opts1(proplists:to_map(Opts), State).

normalize_opts1(Opts, _) when not is_map_key(callback, Opts) ->
	error(missing_callback);
normalize_opts1(Opts, _) when not is_map_key(strategy, Opts) ->
	error(missing_strategy);
normalize_opts1(Opts0, State) ->
	Defaults=#{
		callback_timeout => infinity,
		external_events => postpone,
		timeout_events => ignore,
		success_state => State,
		error_state => State
	},
	Opts1=maps:with([strategy, callback|maps:keys(Defaults)], Opts0),
	Opts2=maps:merge(Defaults, Opts1),
	maps:map(
		fun
			(callback, V) when is_function(V) ->
				V;
			(strategy, {simple, StrategyOpts}) when is_map(StrategyOpts); is_list(StrategyOpts) ->
				{simple, normalize_strategy_opts(StrategyOpts)};
			(strategy, V={custom, Fun}) when is_function(Fun, 1) ->
				V;
			(callback_timeout, infinity) ->
				infinity;
			(callback_timeout, V) when is_integer(V), V>=0 ->
				V;
			(external_events, postpone) ->
				postpone;
			(external_events, ignore) ->
				ignore;
			(external_events, V={reply_or_ignore, _}) ->
				V;
			(timeout_events, ignore) ->
				ignore;
			(timeout_events, postpone) ->
				postpone;
			(success_state, V) ->
				V;
			(error_state, V) ->
				V;
			(K, V) ->
				error({invalid_option, {K, V}})
		end,
		Opts2
	).

normalize_strategy_opts(Opts) when is_map(Opts) ->
	normalize_strategy_opts1(Opts);
normalize_strategy_opts(Opts) when is_list(Opts) ->
	normalize_strategy_opts1(proplists:to_map(Opts)).

normalize_strategy_opts1(Opts0) ->
	Defaults=#{
		max => infinity,
		delay => 0,
		time => 0,
		backoff => 0,
		jitter => 0
	},
	Opts1=maps:with(maps:keys(Defaults), Opts0),
	Opts2=maps:merge(Defaults, Opts1),
	maps:map(
		fun
			(max, infinity) ->
				infinity;
			(max, V) when is_integer(V), V>=0 ->
				V;
			(delay, V) when is_integer(V), V>=0 ->
				V;
			(time, V) when is_integer(V), V>=0 ->
				V;
			(backoff, V) when is_number(V) ->
				V;
			(jitter, V) when is_integer(V) ->
				V;
			(K, V) ->
				error({invalid_strategy_option, {K, V}})
		end,
		Opts2
	).
