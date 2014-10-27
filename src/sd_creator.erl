%%-------------------------------------------------------------------
%%
%% Copyright (c) 2014, James Fish <james@fishcakez.com>
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
-module(sd_creator).

-behaviour(gen_fsm).

%% public api

-export([start_link/11]).
-export([join_acquired/3]).
-export([join_wait/3]).
-export([acquired/2]).
-export([acquired/3]).
-export([leave/2]).
-export([leave/3]).
-export([stop/2]).
-export([stop/3]).

%% gen_fsm api

-export([init/1]).
-export([join/2]).
-export([join/3]).
-export([wait_join/2]).
-export([wait_join/3]).
-export([prepare/2]).
-export([prepare/3]).
-export([wait/2]).
-export([wait/3]).
-export([accept/2]).
-export([accept/3]).
-export([connect/2]).
-export([connect/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([format_status/2]).
-export([terminate/3]).

%% types

-record(config, {id, pool_ref, number, manager, manager_ref, handler_sups,
                 family, creation, target, socket, opts, timeout,
                 min_time_backoff, max_time_backoff, min_error_backoff,
                 max_error_backoff}).
-record(state, {config, handler, handler_info, time_backoff, error_backoff}).

%% public api

start_link(Opts, Timeout, TBackoff, EBackoff, SockInfo, Id, PRef,
           N, Socket, Manager, HandlerSups) ->
    gen_fsm:start_link({via, sd_reg, {Id, {?MODULE, {PRef, N}}}}, ?MODULE,
                       {Id, PRef, N, Manager, HandlerSups, SockInfo, Socket,
                        Opts, Timeout, TBackoff, EBackoff},
                       [{debug, [{log,10}]}]).

join_acquired(Creator, PRef, MRef) ->
    gen_fsm:send_event(Creator, {join_acquired, PRef, MRef}).

join_wait(Creator, PRef, MRef) ->
    gen_fsm:send_event(Creator, {join_wait, PRef, MRef}).

acquired(Creator, MRef) ->
    gen_fsm:send_event(Creator, {acquired, MRef}).

acquired(Creator, MRef, HInfo) ->
    gen_fsm:send_event(Creator, {acquired, MRef, HInfo}).

leave(Creator, MRef) ->
    gen_fsm:send_event(Creator, {leave, MRef}).

leave(Creator, MRef, HInfo) ->
    gen_fsm:send_event(Creator, {leave, MRef, HInfo}).

stop(Creator, MRef) ->
    gen_fsm:send_event(Creator, {stop, MRef}).

stop(Creator, MRef, Reason) ->
    gen_fsm:send_event(Creator, {stop, MRef, Reason}).

%% gen_fsm api

init({Id, PRef, N, Manager, HandlerSups, {Family, Creation, Target}, Socket,
      Opts, Timeout, {MinTBackoff, MaxTBackoff}, {MinEBackoff, MaxEBackoff}}) ->
    HandlerSups2 = list_to_tuple(HandlerSups),
    case start_handler(HandlerSups2, Manager) of
        {ok, Handler, HandlerInfo} when is_pid(Manager) ->
            Config = #config{id=Id, pool_ref=PRef, number=N, manager=Manager,
                             handler_sups=HandlerSups2, family=Family,
                             creation=Creation, target=Target,
                             socket=Socket, opts=Opts, timeout=Timeout,
                             min_time_backoff=MinTBackoff,
                             max_time_backoff=MaxTBackoff,
                             min_error_backoff=MinEBackoff,
                             max_error_backoff=MaxEBackoff},
            State = #state{config=Config, handler=Handler,
                           handler_info=HandlerInfo, time_backoff=MinTBackoff,
                           error_backoff=MinEBackoff},
            {ok, join, State};
        {ok, _Handler, HandlerInfo} when Manager =:= undefined ->
            stop_handler(HandlerInfo),
            {stop, {shutdown, {no_manager, Id}}};
        ignore ->
            ignore;
        {error, Reason} ->
            {stop, {shutdown, {failed_to_start_child, handler, Reason}}}
    end.

join({join_acquired, PRef, MRef},
     #state{config=#config{pool_ref=PRef,
                           creation=Creation} = Config} = State) ->
    State2 = State#state{config=Config#config{manager_ref=MRef}},
    {next_state, Creation, State2, 0};
join({join_wait, PRef, MRef},
     #state{config=#config{pool_ref=PRef} = Config} = State) ->
    State2 = State#state{config=Config#config{manager_ref=MRef}},
    {next_state, wait_join, State2}.

join(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

wait_join({acquired, MRef}, #state{config=#config{manager_ref=MRef,
                                             creation=Creation}} = State) ->
    {next_state, Creation, State, 0};
wait_join({leave, MRef}, #state{config=#config{manager_ref=MRef}} = State) ->
    {stop, normal, State}.

wait_join(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

prepare(timeout, #state{config=#config{pool_ref=PRef, manager=Manager,
                                       manager_ref=MRef,
                                       handler_sups=HandlerSups}} = State) ->
    HandlerSup = handler_sup(HandlerSups),
    sd_handler_sup:acquire(HandlerSup, PRef, Manager, MRef),
    {next_state, wait, State};
prepare({leave, MRef}, #state{config=#config{manager_ref=MRef}} = State) ->
    {stop, normal, State}.

prepare(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.


wait({acquired, MRef, {Handler, HandlerSup, HSChild}},
     #state{config=#config{manager_ref=MRef, creation=Creation}} = State) ->
    State2 = State#state{handler=Handler, handler_info={HandlerSup, HSChild}},
    {next_state, Creation, State2, 0};
wait({stop, MRef}, #state{config=#config{manager_ref=MRef}} = State) ->
    {stop, normal, State};
wait({stop, Reason, MRef},  #state{config=#config{manager_ref=MRef}} = State) ->
    {stop, Reason, State};
wait({leave, MRef, {Handler, HandlerSup, HSChild}},
     #state{config=#config{manager_ref=MRef}} = State) ->
    State2 = State#state{handler=Handler, handler_info={HandlerSup, HSChild}},
    {stop, normal, State2};
wait({leave, MRef}, #state{config=#config{manager_ref=MRef}} = State) ->
    {next_state, wait, State}.

wait(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

accept(timeout, #state{config=#config{family=Family, socket=LSocket,
                                      timeout=Timeout,
                                      max_time_backoff=MaxTBackoff,
                                      max_error_backoff=MaxEBackoff},
                       time_backoff=TBackoff,
                       error_backoff=EBackoff} = State) ->
    case Family:accept(LSocket, Timeout) of
        {ok, Socket} ->
            post_accept(Socket, State);
        {error, closed} ->
            {stop, normal, State};
        {error, einval} ->
            ok = Family:close(LSocket),
            {stop, normal, State};
        {error, timeout} when TBackoff > MaxTBackoff ->
            {next_state, accept, State, MaxTBackoff};
        {error, timeout} ->
            TBackoff2 = TBackoff * 2,
            {next_state, accept, State#state{time_backoff=TBackoff2}, TBackoff};
        {error, Reason} when EBackoff > MaxEBackoff ->
            log_error(Reason, State),
            {next_state, accept, State, MaxEBackoff};
        {error, Reason} ->
            log_error(Reason, State),
            EBackoff2 = EBackoff * 2,
            State2 = State#state{error_backoff=EBackoff2},
            {next_state, accept, State2, EBackoff}
    end;
accept({leave, MRef}, #state{config=#config{manager_ref=MRef}} = State) ->
    {stop, normal, State}.

post_accept(Socket,
            #state{config=#config{pool_ref=PRef, manager=Manager,
                                  opts=[], min_time_backoff=MinTBackoff,
                                  min_error_backoff=MinEBackoff} = Config,
                   handler=Handler}) ->
    erlang:port_connect(Socket, Manager),
    unlink(Socket),
    erlang:port_connect(Socket, Handler),
    Handler ! {socket, PRef, Socket},
    State2 = #state{config=Config, time_backoff=MinTBackoff,
                    error_backoff=MinEBackoff},
    {next_state, prepare, State2, 0};
post_accept(Socket,
            #state{config=#config{pool_ref=PRef, manager=Manager, family=Family,
                                  opts=Opts, min_time_backoff=MinTBackoff,
                                  min_error_backoff=MinEBackoff} = Config,
                   handler=Handler} = State) ->
    case Family:setopts(Socket, Opts) of
        ok ->
            erlang:port_connect(Socket, Manager),
            unlink(Socket),
            erlang:port_connect(Socket, Handler),
            Handler ! {socket, PRef, Socket},
            State2 = #state{config=Config, time_backoff=MinTBackoff,
                            error_backoff=MinEBackoff},
            {next_state, prepare, State2, 0};
        {error, Reason} ->
            Family:close(Socket),
            {stop, {socket_setopts, Reason}, State}
    end.

accept(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

connect(timeout, #state{config=#config{socket=SSocket}} = State) ->
    case sd_seek:info(SSocket) of
        {ok, {Target, Opts2}} ->
            do_connect(Target, Opts2, State);
        {error, closed} ->
            {stop, normal, State}
    end;
connect({leave, MRef}, #state{config=#config{manager_ref=MRef}} = State) ->
    {stop, normal, State}.

do_connect(Target, Opts,
           #state{config=#config{pool_ref=PRef, manager=Manager, family=Family,
                                 opts=Opts2, timeout=Timeout,
                                 min_time_backoff=MinTBackoff,
                                 max_time_backoff=MaxTBackoff,
                                 min_error_backoff=MinEBackoff,
                                 max_error_backoff=MaxEBackoff} = Config,
                  handler=Handler, time_backoff=TBackoff,
                  error_backoff=EBackoff} = State) ->
    try Family:connect(Target, Opts ++ Opts2, Timeout) of
        {ok, Socket} ->
            erlang:port_connect(Socket, Manager),
            unlink(Socket),
            erlang:port_connect(Socket, Handler),
            Handler ! {socket, PRef, Socket},
            State2 = #state{config=Config, time_backoff=MinTBackoff,
                            error_backoff=MinEBackoff},
            {next_state, prepare, State2, 0};
        {error, timeout} when TBackoff > MaxTBackoff ->
            {next_state, connect, State, MaxTBackoff};
        {error, timeout} ->
            TBackoff2 = TBackoff * 2,
            State2 = State#state{time_backoff=TBackoff2},
            {next_state, connect, State2, TBackoff};
        {error, Reason} when EBackoff > MaxEBackoff ->
            log_error(Reason, State),
            {next_state, connect, State, MaxEBackoff};
        {error, Reason} ->
            log_error(Reason, State),
            EBackoff2 = EBackoff * 2,
            State2 = State#state{error_backoff=EBackoff2},
            {next_state, connect, State2, EBackoff}
    catch
        exit:badarg ->
            {stop, {socket_connect, einval}, State}
    end.

connect(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

handle_event(Event, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_sync_event(Event, _From, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_info(_Info, prepare, State) ->
    {next_state, prepare, State, 0};
handle_info(_Info, accept, State) ->
    {next_state, accept, State, 0};
handle_info(_Info, connect, State) ->
    {next_state, connect, State, 0};
handle_info(Info, StateName, State) ->
    error_logger:error_msg("~p~", [Info]),
    {next_state, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

format_status(normal, [_PDict, #state{} = State]) ->
    [{data, [{"StateData", format_state(State)}]}];
format_status(terminate, [_PDict, #state{} = State]) ->
    format_state(State).

format_state(#state{config=#config{} = Config} = State) ->
    CKeys = record_info(fields, config),
    [config | CValues] = tuple_to_list(Config),
    CList = lists:zip(CKeys, CValues),
    SKeys = record_info(fields, state),
    [state | SValues] = tuple_to_list(State#state{config=CList}),
    lists:zip(SKeys, SValues).

terminate(normal, Creation,
          #state{config=#config{pool_ref=PRef, manager=Manager}} = State)
  when Creation =:= accept orelse Creation =:= connect ->
    try
        sd_manager:release(Manager, PRef)
    catch
        %% Manager is down so not part of pool, probably targeter closed due to
        %% manager exit, don't raise.
        exit:{noproc, _MFA} ->
            ok
    end,
    terminate(State);
terminate(normal, _StateName, State) ->
    terminate(State);
terminate(Reason, StateName, State) ->
    ct:pal("~p~n~p~n~p", [Reason, StateName, State]),
    ok.

terminate(#state{config=#config{pool_ref=PRef, manager=Manager,
                                manager_ref=MRef} = Config} = State)
  when is_reference(MRef) ->
    try
        sd_manager:leave(Manager, PRef, MRef)
    catch
        %% Manager is down so not part of pool, don't raise.
        exit:{noproc, _MFA} ->
            ok
    end,
    terminate(State#state{config=Config#config{manager_ref=undefined}});
terminate(#state{handler=Handler, handler_info=HandlerInfo} = State)
  when is_pid(Handler) ->
    stop_handler(HandlerInfo),
    terminate(State#state{handler=undefined, handler_info=undefined});
terminate(_State) ->
    ok.

%% internal

handler_sup(HandlerSups) ->
    N = erlang:system_info(scheduler_id),
    element(N, HandlerSups).

start_handler(HandlerSups, Manager) ->
    HandlerSup = handler_sup(HandlerSups),
    case sd_handler_sup:start_handler(HandlerSup, Manager) of
        {ok, undefined} ->
            ignore;
        {ok, Handler} ->
            {ok, Handler, {HandlerSup, Handler}};
        {ok, Pid, Handler} when is_pid(Handler) ->
            {ok, Handler, {HandlerSup, Pid}};
        {error, _Reason} = Error ->
            Error
    end.

stop_handler({HandlerSup, Handler}) ->
    sd_handler_sup:terminate_handler(HandlerSup, Handler).

log_error(Reason,
          #state{config=#config{id={Name, _Ref} = Id, pool_ref=PRef, number=N,
                                family=Family, creation=Creation, target=Target,
                                opts=Opts}}) ->
    Report = [{sock_drawer, Name}, {creator, {Id, {?MODULE, {PRef, N}}}},
              {reason, Reason}, {family, Family}, {creation, Creation},
              {target, Target}, {options, Opts}],
    error_logger:error_report(Report).
