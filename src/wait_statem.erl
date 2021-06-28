-module(wait_statem).
-behaviour(gen_statem).

-export([enter_wait/1]).
-export([callback_mode/0]).
-export([init/1]).
-export([handle_event/4]).
-export([code_change/4]).

-record(data, {
	ref,
	timer,
	attempt,
	strategy,
	callback,
	from_state,
	return_state_success,
	return_state_error,
	return_data,
	external_events,
	timeout_events
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

init(Args) ->
	erlang:error(not_implemented, [Args]).

handle_event(internal, {init, Opts}, State, Data) ->
	Callback=maps:get(callback, Opts),
	Strategy=maps:get(strategy, Opts),
	FromState=State,
	SuccessState=maps:get(success_state, Opts, State),
	ErrorState=maps:get(error_state, Opts, State),
	ExternalEvents=maps:get(external_events, Opts, postpone),
	TimeoutEvents=maps:get(timeout_events, Opts, ignore),
	Ref=make_ref(),
	{
		next_state,
		{?MODULE, Ref},
		#data{
			ref=Ref,
			attempt=0,
			callback=Callback,
			strategy=Strategy,
			from_state=FromState,
			return_state_success=SuccessState,
			return_state_error=ErrorState,
			return_data=Data,
			external_events=ExternalEvents,
			timeout_events=TimeoutEvents
		},
		[{next_event, internal, sleep}]
	};
handle_event(internal, sleep, {?MODULE, Ref}, Data=#data{ref=Ref}) ->
	case get_timeout(Data#data.attempt, Data#data.strategy) of
		error ->
			{
				next_state,
				Data#data.return_state_error,
				Data#data.return_data,
				[pop_callback_module]
			};
		{ok, 0} ->
			{
				keep_state,
				Data#data{
					timer=instant,
					attempt=Data#data.attempt+1
				},
				[{next_event, info, {timeout, instant, wakeup}}]
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
handle_event(info, {timeout, Timer0, wakeup}, {?MODULE, Ref}, Data=#data{ref=Ref, timer=Timer0, callback=Callback}) ->
	case Callback(Data#data.return_data) of
		{ok, NewReturnData} ->
			{
				next_state,
				Data#data.return_state_success,
				NewReturnData,
				[pop_callback_module]
			};
		{error, NewReturnData} ->
			{
				keep_state,
				Data#data{
					timer=undefined,
					return_data=NewReturnData
				},
				[{next_event, internal, sleep}]
			}
	end;
handle_event({call, _From}, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events=ignore}) ->
	keep_state_and_data;
handle_event({call, _From}, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events=postpone}) ->
	{keep_state_and_data, [postpone]};
handle_event({call, From}, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events={reply_or_ignore, Reply}}) ->
	{keep_state_and_data, [{reply, From, Reply}]};
handle_event(cast, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events=ignore}) ->
	keep_state_and_data;
handle_event(cast, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events=postpone}) ->
	{keep_state_and_data, [postpone]};
handle_event(cast, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events={reply_or_ignore, _Reply}}) ->
	keep_state_and_data;
handle_event(info, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events=ignore}) ->
	keep_state_and_data;
handle_event(info, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events=postpone}) ->
	{keep_state_and_data, [postpone]};
handle_event(info, _Msg, {?MODULE, Ref}, #data{ref=Ref, external_events={reply_or_ignore, _Reply}}) ->
	keep_state_and_data;
handle_event({timeout, _Name}, _Msg, {?MODULE, Ref}, #data{ref=Ref, timeout_events=ignore}) ->
	keep_state_and_data;
handle_event({timeout, _Name}, _Msg, {?MODULE, Ref}, #data{ref=Ref, timeout_events=postpone}) ->
	{keep_state_and_data, [postpone]};
handle_event(_Type, _Msg, _State, _Data) ->
	keep_state_and_data.

code_change(_OldVsn, State, Data, _Extra) ->
	{ok, State, Data}.

get_timeout(0, {simple, Opts}) when not is_map_key(delay, Opts) ->
	{ok, 0};
get_timeout(0, {simple, #{delay:=Delay}}) ->
	{ok, Delay};
get_timeout(N, {simple, Opts}) when is_map(Opts) ->
	case maps:get(max, Opts, infinity) of
		Max when is_integer(Max), N=<Max; Max=:=infinity ->
			Time=maps:get(time, Opts, 0),
			Backoff=maps:get(backoff, Opts, 0),
			Jitter=maps:get(jitter, Opts, 0),
			Timeout=round((math:pow(N, Backoff) * Time) + (rand:uniform() * Jitter)),
			{ok, Timeout};
		_ ->
			error
	end;
get_timeout(N, {custom, Fun}) when is_function(Fun, 1) ->
	Fun(N).
