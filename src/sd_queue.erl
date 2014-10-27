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
-module(sd_queue).

-behaviour(gen_fsm).

%% public api

-export([start_link/4]).

%% gen_fsm api

-export([init/1]).
-export([ready/2]).
-export([ready/3]).
-export([busy/2]).
-export([busy/3]).
-export([reload/2]).
-export([reload/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([terminate/3]).

%% types

-record(config, {id, mod, args, pool_ref=make_ref(), max_sockets,
                 creators=sd_creators:new(), handlers=handlers()}).
-record(state, {config, locks=0, waiters=[], workers=[]}).
-record(reload, {old_pool_ref, pool_ref, state, state_name, watcher, ack_ref,
                 old, old_handlers, old_workers}).


%% callbacks

-callback init(Args :: term()) ->
    {ok, MaxSockets :: non_neg_integer() | infinity} | ignore.

%% public api

-spec start_link(Id, Mod, Args, Opts) ->
    {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      Mod :: module(),
      Args :: term(),
      Opts :: list(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, Mod, Args, Opts) ->
    gen_fsm:start_link({via, sd_reg, {Id, sd_manager}}, ?MODULE,
                       {Id, Mod, Args}, Opts).

%% gen_fsm api

init({Id, Mod, Args}) ->
    process_flag(trap_exit, true),
    case catch Mod:init(Args) of
        {ok, MaxSockets}
          when (is_integer(MaxSockets) andalso MaxSockets >= 0) orelse
               MaxSockets =:= infinity ->
            Config = #config{id=Id, mod=Mod, args=Args, max_sockets=MaxSockets},
            State = #state{config=Config},
            {ok, busy, State};
        ignore ->
            ignore;
        {'EXIT', Reason} ->
            {stop, Reason};
        Other ->
            exit({bad_return, {Mod, init, Other}})
    end.

ready({checkin, PRef, Handler, HRef},
      #state{config=#config{pool_ref=PRef}, workers=Workers} = State) ->
    {next_state, ready, State#state{workers=[{Handler, HRef} | Workers]}};
ready({checkin, _OldPRef, Handler, HRef}, State) ->
    sd_worker:stop(Handler, HRef),
    {next_state, ready, State};
ready({acquire, PRef, Creator, MRef, HInfo}, State) ->
    State2 = acquire(PRef, Creator, MRef, HInfo, State),
    {next_state, ready, State2}.

ready(checkout, {Pid, CRef}, #state{workers=[{Handler, HRef}]} = State) ->
    sd_worker:checkout(Handler, HRef, Pid, CRef),
    {reply, {ok, Handler, CRef}, busy, State#state{workers=[]}};
ready(checkout, {Pid, CRef},
      #state{workers=[{Handler, HRef} | Workers]} = State) ->
    sd_worker:checkout(Handler, HRef, Pid, CRef),
    {reply, {ok, Handler, CRef}, ready, State#state{workers=Workers}};
ready({checkin, PRef, Handler}, _From,
      #state{config=#config{pool_ref=PRef,
                            handlers=Handlers} = Config,
             workers=Workers} = State) ->
    {HRef, Handlers2} = add_handler(Handler, Handlers),
    Config2 = Config#config{handlers=Handlers2},
    Workers2 = [{Handler, HRef} | Workers],
    State2 = State#state{config=Config2, workers=Workers2},
    {reply, {ok, HRef}, ready, State2};
ready({checkin, _OldPRef, _Handler}, _From,
      #state{config=#config{pool_ref=PRef}} = State) ->
    {reply, {error, {already_started, PRef}}, ready, State};
ready({remove, PRef, Handler, HRef}, _From,
      #state{config=#config{pool_ref=PRef}, workers=Workers} = State) ->
    case remove_worker({Handler, HRef}, Workers) of
        [] ->
            {reply, ok, busy, State#state{workers=[]}};
        Workers2 when is_list(Workers2) ->
            {reply, ok, ready, State#state{workers=Workers2}};
        not_found ->
            {reply, {error, not_found}, ready, State}
    end;
ready({remove, _OldPRef, _Handler, _HRef}, _From, State) ->
    {reply, {error, not_found}, ready, State};
ready({leave, PRef, Creator, MRef}, _From, State) ->
    {Reply, State2} = leave(PRef, Creator, MRef, State),
    {reply, Reply, ready, State2};
ready({release, PRef}, _From, State) ->
    {Reply, State2} = release(PRef, State),
    {reply, Reply, ready, State2};
ready({join, PRef, Watcher, ARef, Creators}, _From, State) ->
    join(PRef, Watcher, ARef, Creators, State);
ready(which_creators, _From, State) ->
    {reply, which_creators(State), ready, State}.

which_creators(#state{config=#config{creators=Creators}}) ->
    ToList = fun({Creator, _MRef}, Acc) -> [Creator | Acc] end,
    gb_sets:fold(ToList, [], Creators).


busy({checkin, PRef, Handler, HRef},
     #state{config=#config{pool_ref=PRef}} = State) ->
    {next_state, ready, State#state{workers=[{Handler, HRef}]}};
busy({checkin, _OldPRef, Handler, HRef}, State) ->
    sd_worker:stop(Handler, HRef),
    {next_state, busy, State};
busy({acquire, PRef, Creator, MRef, HInfo}, State) ->
    State2 = acquire(PRef, Creator, MRef, HInfo, State),
    {next_state, busy, State2}.

busy(checkout, _From, State) ->
    {reply, {error, busy}, busy, State};
busy({checkin, PRef, Handler}, _From,
     #state{config=#config{pool_ref=PRef,
                           handlers=Handlers} = Config} = State) ->
    {HRef, Handlers2} = add_handler(Handler, Handlers),
    Config2 = Config#config{handlers=Handlers2},
    State2 = State#state{config=Config2, workers=[{Handler, HRef}]},
    {reply, {ok, HRef}, ready, State2};
busy({checkin, _OldPRef, _Handler}, _From,
      #state{config=#config{pool_ref=PRef}} = State) ->
    {reply, {error, {already_started, PRef}}, busy, State};
busy({remove, PRef, _Handler, _HRef}, _From,
     #state{config=#config{pool_ref=PRef}} = State) ->
    {reply, {error, not_found}, ready, State};
busy({remove, OldPRef, _Handler, _HRef}, _From,
     #state{config=#config{pool_ref=PRef}} = State) when OldPRef =/= PRef ->
    {reply, {error, not_found}, busy, State};
busy({leave, PRef, Creator, MRef}, _From, State) ->
    {Reply, State2} = leave(PRef, Creator, MRef, State),
    {reply, Reply, busy, State2};
busy({release, PRef}, _From, State) ->
    {Reply, State2} = release(PRef, State),
    {reply, Reply, busy, State2};
busy({join, PRef, Watcher, ARef, Creators}, _From, State) ->
    join(PRef, Watcher, ARef, Creators, State);
busy(which_creators, _From, State) ->
    {reply, which_creators(State), busy, State}.

reload({checkin, PRef, _Handler, _HRef} = CheckIn,
       #reload{pool_ref=PRef, state_name=StateName, state=State} = Reload) ->
    {next_state, StateName2, State2} = ?MODULE:StateName(CheckIn, State),
    {next_state, reload, Reload#reload{state_name=StateName2, state=State2}};
reload({checkin, OldPRef, Handler, HRef},
       #reload{old_pool_ref=OldPRef, old_workers=OldWorkers} = Reload) ->
    Reload2 = Reload#reload{old_workers=[{Handler, HRef} | OldWorkers]},
    {next_state, reload, Reload2};
reload({checkin, _OlderPRef, Handler, HRef}, Reload) ->
    sd_worker:stop(Handler, HRef),
    {next_state, reload, Reload};
reload({acquire, PRef, Creator, MRef, HInfo},
       #reload{pool_ref=PRef, state=State} = Reload) ->
    State2 = acquire(PRef, Creator, MRef, HInfo, State),
    {next_state, reload, Reload#reload{state=State2}};
reload({acquire, OldPRef, Creator, MRef, HInfo},
       #reload{old_pool_ref=OldPRef} = Reload) ->
    sd_creator:leave(Creator, MRef, HInfo),
    {next_state, reload, Reload}.

reload(checkout, {Pid, CRef},
       #reload{old_workers=[{Handler, HRef} | OldWorkers]} = Reload) ->
    sd_worker:checkout(Handler, HRef, Pid, CRef),
    Reload2 = Reload#reload{old_workers=OldWorkers},
    {reply, {ok, Handler, CRef}, reload, Reload2};
reload(checkout, From, #reload{state_name=StateName, state=State} = Reload) ->
    {reply, Reply, StateName2, State2} = ?MODULE:StateName(checkout, From,
                                                           State),
    {reply, Reply, reload, Reload#reload{state_name=StateName2, state=State2}};
reload({checkin, PRef, _Handler} = CheckIn, From,
     #reload{pool_ref=PRef, state_name=StateName, state=State} = Reload) ->
    {reply, Reply, StateName2, State2} = ?MODULE:StateName(CheckIn, From,
                                                           State),
    {reply, Reply, reload, Reload#reload{state_name=StateName2, state=State2}};
reload({checkin, OldPRef, Handler}, _From,
       #reload{old_pool_ref=OldPRef, old_handlers=OldHandlers,
               old_workers=OldWorkers} = Reload) ->
    {HRef, OldHandlers2} = add_handler(Handler, OldHandlers),
    OldWorkers2 = [{Handler, HRef} | OldWorkers],
    Reload2 = Reload#reload{old_handlers=OldHandlers2, old_workers=OldWorkers2},
    {reply, {ok, HRef}, reload, Reload2};
reload({checkin, _OlderPRef, _Handler}, _From,
       #reload{pool_ref=PRef} = Reload) ->
    {reply, {error, {already_started, PRef}}, reload, Reload};
reload({remove, PRef, _Handler, _HRef} = Remove, From,
       #reload{pool_ref=PRef, state_name=StateName, state=State} = Reload) ->
    {reply, Reply, StateName2, State2} = ?MODULE:StateName(Remove, From, State),
    Reload2 = Reload#reload{state_name=StateName2, state=State2},
    {reply, Reply, reload, Reload2};
reload({remove, OldPRef, Handler, HRef}, _From,
       #reload{pool_ref=OldPRef, old_workers=OldWorkers} = Reload) ->
    case remove_worker({Handler, HRef}, OldWorkers) of
        not_found ->
            {reply, {error, not_found}, reload, Reload};
        OldWorkers2 ->
            {reply, ok, reload, Reload#reload{old_workers=OldWorkers2}}
    end;
reload({remove, _OlderPRef, _Handler, _HRef}, _From, Reload) ->
    {reply, {error, not_found}, reload, Reload};
reload({leave, OldPRef, Creator, MRef}, _From,
       #reload{old_pool_ref=OldPRef, state_name=StateName,
               state=#state{config=#config{handlers=Handlers} = Config}= State,
               watcher=Watcher, ack_ref=ARef, old=Old, old_handlers=OldHandlers,
               old_workers=OldWorkers} = Reload) ->
    Old2 = sd_creators:left({Creator, MRef}, Old),
    case gb_sets:size(Old2) of
        0 ->
            sd_watcher:init_ack(Watcher, ARef),
            OldHandlers2 = stop_workers(OldWorkers, OldHandlers),
            Handlers2 = merge_handlers(OldHandlers2, Handlers),
            Config2 = Config#config{handlers=Handlers2},
            {reply, ok, StateName, State#state{config=Config2}};
        _Other ->
            {reply, ok, reload, Reload#reload{old=Old2}}
    end;
reload({leave, PRef, _Creator, _MRef} = Leave, From,
       #reload{pool_ref=PRef, state_name=StateName, state=State} = Reload) ->
    {reply, Reply, StateName, State2} = ?MODULE:StateName(Leave, From, State),
    {reply, Reply, reload, Reload#reload{state=State2}};
reload({release, OldPRef}, From,
       #reload{old_pool_ref=OldPRef, pool_ref=PRef} = Reload) ->
    reload({release, PRef}, From, Reload);
reload({release, PRef} = Release, From,
       #reload{pool_ref=PRef, state_name=StateName, state=State} = Reload) ->
    {reply, Reply, StateName, State2} = ?MODULE:StateName(Release, From, State),
    {reply, Reply, reload, Reload#reload{state=State2}};
reload({join, _PRef, _Watcher, _ARef, _Creators}, _From,
       #reload{pool_ref=PRef} = Reload) ->
    {reply, {error, {already_reloading, PRef}}, reload, Reload};
reload(which_creators, _From, #reload{old=Old, state=State} = Reload) ->
    NewList = which_creators(State),
    ToList = fun({Creator, _MRef}, Acc) -> [Creator | Acc] end,
    Reply = gb_sets:fold(ToList, NewList, Old),
    {reply, Reply, reload, Reload}.

handle_event(Event, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_sync_event(Event, _From, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_info({'EXIT', Socket, _Reason}, reload,
            #reload{state=State} = Reload) when is_port(Socket) ->
    State2 = handle_exit(State),
    {next_state, reload, Reload#reload{state=State2}};
handle_info({'EXIT', Socket, _Reason}, StateName, State) when is_port(Socket) ->
    State2 = handle_exit(State),
    {next_state, StateName, State2};
handle_info({'EXIT', _Pid, normal}, StateName, State) ->
    {next_state, StateName, State};
handle_info({'EXIT', _Pid, Reason}, _StateName, State) ->
    {stop, Reason, State};
handle_info({'DOWN', MRef, _, Pid, Reason}, ready, State) ->
    ready_down({Pid, MRef}, Reason, State);
handle_info({'DOWN', MRef, _, Pid, Reason}, busy, State) ->
    busy_down({Pid, MRef}, Reason, State);
handle_info({'DOWN', MRef, _, Pid, Reason}, reload, Reload) ->
    reload_down({Pid, MRef}, Reason, Reload).

reload_down(Elem, Reason, #reload{old_handlers=OldHandlers,
                                  old_workers=OldWorkers,
                                  state_name=StateName} = Reload) ->
    case down_handler(Elem, OldWorkers, OldHandlers) of
        {OldWorkers2, OldHandlers2} ->
            Reload2 = Reload#reload{old_handlers=OldHandlers2,
                                    old_workers=OldWorkers2},
            {next_state, reload, Reload2};
        not_found when StateName =:= ready ->
            reload_down(Elem, Reason, fun ready_down/3, Reload);
        not_found when StateName =:= busy ->
            reload_down(Elem, Reason, fun busy_down/3, Reload)
    end.

reload_down(Elem, Reason, Handle, #reload{state=State} = Reload) ->
    case Handle(Elem, Reason, State) of
        {next_state, StateName2, State2} ->
            Reload2 = Reload#reload{state_name=StateName2,
                                    state=State2},
            {next_state, reload, Reload2};
        {stop, Reason, State2} ->
            {stop, Reason, Reload#reload{state=State2}}
    end.

ready_down(Elem, Reason,
           #state{config=#config{handlers=Handlers} = Config,
                  workers=Workers} = State) ->
    case down_handler(Elem, Workers, Handlers) of
        {[], Handlers2} ->
            Config2 = Config#config{handlers=Handlers2},
            {next_state, busy, State#state{config=Config2, workers=[]}};
        {Workers2, Handlers2} ->
            Config2 = Config#config{handlers=Handlers2},
            {next_state, ready, State#state{config=Config2, workers=Workers2}};
        not_found ->
            {Pid, _} = Elem,
            {stop, {shutdown, {bad_creator, Pid, Reason}}, State}
    end.

busy_down(Elem, Reason,
           #state{config=#config{handlers=Handlers} = Config} = State) ->
    case down_handler(Elem, [], Handlers) of
        {[], Handlers2} ->
            Config2 = Config#config{handlers=Handlers2},
            {next_state, busy, State#state{config=Config2}};
        not_found ->
            {Pid, _} = Elem,
            {stop, {shutdown, {bad_creator, Pid, Reason}}, State}
    end.

code_change(OldVsn, reload, #reload{state_name=StateName, state=State} = Reload,
            Extra) ->
    case code_change(OldVsn, StateName, State, Extra) of
        {ok, StateName, State2} ->
            {ok, reload, Reload#reload{state=State2}};
        {error, _Reason} = Error ->
            Error
    end;
code_change(_OldVsn, StateName, State, _Extra) ->
    case code_change(State) of
        {ok, State2} ->
            {ok, StateName, State2};
        {error, _Reason} = Error ->
            Error
    end.

code_change(#state{config=#config{mod=Mod, args=Args}} = State) ->
    case catch Mod:init(Args) of
        {ok, infinity} ->
            code_change(infinity, State);
        {ok, MaxSockets} when is_integer(MaxSockets) andalso MaxSockets >= 0 ->
            code_change(MaxSockets, State);
        ignore ->
            {ok, State};
        {'EXIT', Reason} ->
            {error, Reason};
        Other ->
            {error, {bad_return, {Mod, init, Other}}}
    end.

code_change(MaxSockets,
            #state{config=Config, locks=Locks, waiters=Waiters} = State)
  when MaxSockets > Locks ->
    {Locks2, Waiters2} = acquired_waiters(MaxSockets, Locks, Waiters),
    Config2 = Config#config{max_sockets=MaxSockets},
    {ok, State#state{config=Config2, locks=Locks2, waiters=Waiters2}};
code_change(MaxSockets, #state{config=Config} = State) ->
    {ok, State#state{config=Config#config{max_sockets=MaxSockets}}}.

acquired_waiters(MaxSockets, MaxSockets, Waiters) ->
    {MaxSockets, Waiters};
acquired_waiters(_MaxSockets, Locks, []) ->
    {Locks, []};
acquired_waiters(MaxSockets, Locks, [{Creator, MRef, HInfo} | Waiters]) ->
    sd_creator:acquired(Creator, MRef, HInfo),
    acquired_waiters(MaxSockets, Locks+1, Waiters);
acquired_waiters(MaxSockets, Locks, [{Creator, MRef} | Waiters]) ->
    sd_creator:acquired(Creator, MRef),
    acquired_waiters(MaxSockets, Locks+1, Waiters).

terminate(_Reason, _StateName, _State) ->
    ok.

handle_exit(#state{config=#config{max_sockets=MaxSockets},
                   locks=Locks} = State) when MaxSockets > Locks ->
    State#state{locks=Locks-1};
handle_exit(#state{waiters=[{Creator, MRef, HInfo} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef, HInfo),
    State#state{waiters=Waiters};
handle_exit(#state{waiters=[{Creator, MRef} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef),
    State#state{waiters=Waiters};
handle_exit(#state{locks=Locks, waiters=[]} = State) ->
    State#state{locks=Locks-1}.

%% handlers

handlers() ->
    gb_sets:new().

add_handler(Handler, Handlers) ->
    HRef = monitor(process, Handler),
    {HRef, gb_sets:insert({Handler, HRef}, Handlers)}.

merge_handlers(HandlersA, HandlersB) ->
    gb_sets:union(HandlersA, HandlersB).

down_handler(Handler, Workers, Handlers) ->
    try gb_sets:delete(Handler, Handlers) of
        Handlers2 ->
            {down_worker(Handler, Workers), Handlers2}
    catch
        error:function_clause ->
            not_found
    end.

down_worker(Handler, Workers) ->
    case remove_worker(Handler, Workers) of
        not_found ->
            Workers;
        Workers2 ->
            Workers2
    end.

remove_worker(Handler, Workers) ->
    case lists:member(Handler, Workers) of
        true ->
            delete_worker(Handler, Workers);
        false ->
            not_found
    end.

delete_worker(Handler, Workers) ->
    delete_worker(Handler, Workers, []).

%% Asserts Handler in Workers
delete_worker(Handler, [Handler | Workers], Acc) ->
    lists:reverse(Acc, Workers);
delete_worker(Handler, [Other | Workers], Acc) ->
    delete_worker(Handler, Workers, [Other | Acc]).

stop_workers([], Handlers) ->
    Handlers;
stop_workers([{Handler, HRef} = Elem | Workers], Handlers) ->
    demonitor(HRef, [flush]),
    sd_worker:stop(Handler, HRef),
    stop_workers(Workers, gb_sets:delete(Elem, Handlers)).

%% creators

acquire(PRef, Creator, MRef, HInfo,
        #state{config=#config{pool_ref=PRef, max_sockets=MaxSockets},
               locks=Locks} = State) when MaxSockets > Locks ->
    sd_creator:acquired(Creator, MRef, HInfo),
    State#state{locks=Locks+1};
acquire(PRef, Creator, MRef, HInfo,
        #state{config=#config{pool_ref=PRef}, waiters=Waiters} = State) ->
    State#state{waiters=[{Creator, MRef, HInfo} | Waiters]}.


leave(PRef, Creator, MRef, #state{config=#config{pool_ref=PRef,
                           creators=Creators} = Config} = State) ->
    Creators2 = sd_creators:left({Creator, MRef}, Creators),
    Config2 = Config#config{creators=Creators2},
    {ok, State#state{config=Config2}}.


release(PRef, #state{config=#config{pool_ref=PRef, max_sockets=MaxSockets},
                     locks=Locks} = State) when MaxSockets > Locks ->
    {ok, State#state{locks=Locks-1}};
release(PRef, #state{config=#config{pool_ref=PRef},
                     waiters=[{Creator, MRef} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef),
    {ok, State#state{waiters=Waiters}};
release(PRef, #state{config=#config{pool_ref=PRef},
                     waiters=[{Creator, MRef, HInfo} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef, HInfo),
    {ok, State#state{waiters=Waiters}};
release(PRef, #state{config=#config{pool_ref=PRef},
                     locks=Locks, waiters=[]} = State) ->
    {ok, State#state{locks=Locks-1}}.

join(PRef, Watcher, ARef, Creators,
     #state{config=#config{pool_ref=OldPRef, max_sockets=MaxSockets,
                           creators=Old, handlers=Handlers} = Config,
            locks=Locks, waiters=OldWaiters, workers=OldWorkers})
  when PRef =/= OldPRef ->
    {Locks2, Waiters, New} = sd_creators:join(Creators, PRef, MaxSockets,
                                              Locks),
    Old2 = sd_creators:leave(OldWaiters, Old),
    ok = sd_creators:leave(Old2),
    Config2 = Config#config{pool_ref=PRef, handlers=handlers(), creators=New},
    State = #state{config=Config2, locks=Locks2, waiters=Waiters},
    case gb_sets:size(Old) of
        0 ->
            sd_watcher:init_ack(Watcher, ARef),
            Handlers2 = stop_workers(OldWorkers, Handlers),
            Config3 = Config2#config{handlers=Handlers2},
            State2 = State#state{config=Config3},
            {reply, {ok, ARef}, busy, State2};
        _Other ->
            Reload = #reload{old_pool_ref=OldPRef, pool_ref=PRef,
                             state_name=busy, state=State,
                             watcher=Watcher, ack_ref=ARef, old=Old,
                             old_handlers=Handlers, old_workers=OldWorkers},
            {reply, {ok, ARef}, reload, Reload}
    end.
