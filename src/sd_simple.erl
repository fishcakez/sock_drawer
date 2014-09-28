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
-module(sd_simple).

-behaviour(gen_fsm).

%% public api

-export([start_link/4]).

%% gen_fsm api

-export([init/1]).
-export([ready/2]).
-export([ready/3]).
-export([full/2]).
-export([full/3]).
-export([reload/2]).
-export([reload/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([format_status/2]).
-export([terminate/3]).

%% types

-record(config, {id, mod, args, pool_ref=make_ref(), max_sockets,
                 creators=gb_sets:new()}).
-record(state, {config, locks=0, waiters=[]}).
-record(reload, {old_pool_ref, pool_ref, state, state_name, watcher, ack_ref,
                 old}).

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
        {ok, 0} ->
            Config = #config{id=Id, mod=Mod, args=Args, max_sockets=0},
            State = #state{config=Config},
            {ok, full, State};
        {ok, MaxSockets}
          when (is_integer(MaxSockets) andalso MaxSockets >= 0) orelse
               MaxSockets =:= infinity ->
            Config = #config{id=Id, mod=Mod, args=Args, max_sockets=MaxSockets},
            State = #state{config=Config},
            {ok, ready, State};
        ignore ->
            ignore;
        {'EXIT', Reason} ->
            {stop, Reason};
        Other ->
            exit({bad_return, {Mod, init, Other}})
    end.

ready({acquire, PRef, Creator, MRef, HInfo},
      #state{config=#config{pool_ref=PRef, max_sockets=MaxSockets},
             locks=Locks} = State) ->
    sd_creator:acquired(Creator, MRef, HInfo),
    Locks2 = Locks + 1,
    State2 = State#state{locks=Locks2},
    case Locks2 of
        MaxSockets ->
            {next_state, full, State2};
        _Other ->
            {next_state, ready, State2}
    end.


ready({leave, PRef, Creator, MRef}, _From, #state{config=Config} = State) ->
    Config2 = leave_config(PRef, Creator, MRef, Config),
    {reply, ok, ready, State#state{config=Config2}};
ready({release, PRef}, _From, #state{config=#config{pool_ref=PRef},
                                     locks=Locks} = State) ->
    {reply, ok, ready, State#state{locks=(Locks-1)}};
ready({join, PRef, Watcher, ARef, Creators}, _From,
      #state{config=#config{pool_ref=OldPRef, max_sockets=MaxSockets,
                            creators=Old} = Config,
             locks=Locks} = State) when PRef =/= OldPRef ->
    {StateName, Locks2, Waiters, New} = ready_join(Creators, PRef, MaxSockets,
                                                   Locks),
    ok = leave_old(Old),
    Config2 = Config#config{pool_ref=PRef, creators=New},
    State2 = State#state{config=Config2,locks=Locks2, waiters=Waiters},
    case gb_sets:size(Old) of
        0 ->
            sd_watcher:init_ack(Watcher, ARef),
            {reply, {ok, ARef}, StateName, State2};
        _Other ->
            Reload = #reload{old_pool_ref=OldPRef, pool_ref=PRef,
                             state_name=StateName, state=State2,
                             watcher=Watcher, ack_ref=ARef, old=Old},
            {reply, {ok, ARef}, reload, Reload}
    end;
ready(which_creators, _From, State) ->
    {reply, which_creators(State), ready, State}.

ready_join(Creators, PRef, MaxSockets, Locks) ->
    ready_join(Creators, PRef, MaxSockets, Locks, gb_sets:new()).

ready_join(Creators, PRef, MaxSockets, MaxSockets, New) ->
    {Waiters, New2} = full_join(Creators, PRef, [], New),
    {full, MaxSockets, Waiters, New2};
ready_join([], _PRef, _MaxSockets, Locks, New) ->
    {ready, Locks, [], New};
ready_join([Creator | Creators], PRef, MaxSockets, Locks, New) ->
    MRef = monitor(process, Creator),
    sd_creator:join_acquired(Creator, PRef, MRef),
    Elem = {Creator, MRef},
    New2 = gb_sets:insert(Elem, New),
    ready_join(Creators, PRef, MaxSockets, Locks+1, New2).

leave_old(Old) ->
    Leave = fun({Creator, MRef}, Acc) ->
                    sd_creator:leave(Creator, MRef),
                    Acc
            end,
    gb_sets:fold(Leave, ok, Old).

which_creators(#state{config=#config{creators=Creators}}) ->
    ToList = fun({Creator, _MRef}, Acc) -> [Creator | Acc] end,
    gb_sets:fold(ToList, [], Creators).

full({acquire, PRef, Creator, MRef, HInfo},
     #state{config=#config{pool_ref=PRef}, waiters=Waiters} = State) ->
    {next_state, full, State#state{waiters=[{Creator, MRef, HInfo} | Waiters]}}.

leave_config(PRef, Creator, MRef,
             #config{pool_ref=PRef, creators=Creators} = Config) ->
    demonitor(MRef, [flush]),
    Creators2 = gb_sets:delete({Creator, MRef}, Creators),
    Config#config{creators=Creators2}.

full({leave, PRef, Creator, MRef}, _From, #state{config=Config} = State) ->
    Config2 = leave_config(PRef, Creator, MRef, Config),
    {reply, ok, full, State#state{config=Config2}};
full({release, PRef}, _From,
     #state{config=#config{pool_ref=PRef, max_sockets=MaxSockets},
            locks=MaxSockets,
            waiters=[{Creator, MRef, HInfo} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef, HInfo),
    {reply, ok, full, State#state{waiters=Waiters}};
full({release, PRef}, _From,
     #state{config=#config{pool_ref=PRef, max_sockets=MaxSockets},
            locks=MaxSockets, waiters=[{Creator, MRef} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef),
    {reply, ok, full, State#state{waiters=Waiters}};
full({release, PRef}, _From,
     #state{config=#config{pool_ref=PRef, max_sockets=MaxSockets},
            locks=MaxSockets, waiters=[]} = State) ->
    {reply, ok, ready, State#state{locks=(MaxSockets-1)}};
full({release, PRef}, _From, #state{config=#config{pool_ref=PRef},
                                    locks=Locks} = State) ->
    {reply, ok, full, State#state{locks=(Locks-1)}};
full({join, PRef, Watcher, ARef, Creators}, _From,
      #state{config=#config{pool_ref=OldPRef, creators=Old} = Config,
            waiters=Waiters} = State) when PRef =/= OldPRef ->
    {Waiters2, New} = full_join(Creators, PRef),
    Old2 = leave_waiters(Waiters, Old),
    ok = leave_old(Old2),
    Config2 = Config#config{pool_ref=PRef, creators=New},
    State2 = State#state{config=Config2, waiters=Waiters2},
    case gb_sets:size(Old) of
        0 ->
            sd_watcher:init_ack(Watcher, ARef),
            {reply, {ok, ARef}, full, State2};
        _Other ->
            Reload = #reload{old_pool_ref=OldPRef, pool_ref=PRef,
                             state_name=full, state=State2,
                             watcher=Watcher, ack_ref=ARef, old=Old},
            {reply, {ok, ARef}, reload, Reload}
    end;
full(which_creators, _From,
     #state{config=#config{creators=Creators}} = State) ->
    ToList = fun({Creator, _MRef}, Acc) -> [Creator | Acc] end,
    Reply = gb_sets:fold(ToList, [], Creators),
    {reply, Reply, full, State}.

full_join(Creators, PRef) ->
    full_join(Creators, PRef, [], gb_sets:new()).

full_join([], _PRef, Waiters, New) ->
    {Waiters, New};
full_join([Creator | Creators], PRef, Waiters, New) ->
    MRef = monitor(process, Creator),
    sd_creator:join_wait(Creator, PRef, MRef),
    Elem = {Creator, MRef},
    New2 = gb_sets:insert(Elem, New),
    full_join(Creators, PRef, [Elem | Waiters], New2).

leave_waiters([], Old) ->
    Old;
leave_waiters([{Creator, MRef, HInfo} | Waiters], Old) ->
    sd_creator:leave(Creator, MRef, HInfo),
    leave_waiters(Waiters, gb_sets:delete({Creator, MRef}, Old));
leave_waiters([{Creator, MRef} = Elem | Waiters], Old) ->
    sd_creator:leave(Creator, MRef),
    leave_waiters(Waiters, gb_sets:delete(Elem, Old)).

reload({acquire, PRef, _Creator, _MRef, _HInfo} = Acquire,
       #reload{pool_ref=PRef, state_name=StateName, state=State} = Reload) ->
    {next_state, StateName2, State2} = ?MODULE:StateName(Acquire, State),
    {next_state, reload, Reload#reload{state_name=StateName2, state=State2}};
reload({acquire, OldPRef, Creator, MRef, HInfo},
       #reload{old_pool_ref=OldPRef} = Reload) ->
    sd_creator:leave(Creator, MRef, HInfo),
    {next_state, reload, Reload}.

reload({leave, OldPRef, Creator, MRef}, _From,
       #reload{old_pool_ref=OldPRef, state_name=StateName, state=State,
               watcher=Watcher, ack_ref=ARef, old=Old} = Reload) ->
    demonitor(MRef, [flush]),
    Old2 = gb_sets:delete({Creator, MRef}, Old),
    case gb_sets:size(Old2) of
        0 ->
            sd_watcher:init_ack(Watcher, ARef),
            {reply, ok, StateName, State};
        _Other ->
            {reply, ok, reload, Reload#reload{old=Old2}}
    end;
reload({leave, PRef, _Creator, _MRef} = Leave, From,
       #reload{pool_ref=PRef, state_name=ready, state=State} = Reload) ->
    {reply, Reply, ready, State2} = ready(Leave, From, State),
    {reply, Reply, reload, Reload#reload{state=State2}};
reload({leave, PRef, _Creator, _MRef} = Leave, From,
       #reload{pool_ref=PRef, state_name=full, state=State} = Reload) ->
    {reply, Reply, full, State2} = full(Leave, From, State),
    {reply, Reply, reload, Reload#reload{state=State2}};
reload({release, OldPRef}, From,
       #reload{old_pool_ref=OldPRef, pool_ref=PRef} = Reload) ->
    reload({release, PRef}, From, Reload);
reload({release, PRef} = Release, From,
       #reload{pool_ref=PRef, state_name=ready, state=State} = Reload) ->
    {reply, Reply, ready, State2} = ready(Release, From, State),
    {reply, Reply, reload, Reload#reload{state=State2}};
reload({release, PRef} = Release, From,
       #reload{pool_ref=PRef, state_name=full, state=State} = Reload) ->
    {reply, Reply, StateName, State2} = full(Release, From, State),
    {reply, Reply, reload, Reload#reload{state_name=StateName, state=State2}};
reload({join, _NewPRef, _Watcher, _ARef, _Creators}, _From,
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

handle_info({'EXIT', Socket, _Reason}, ready, State) when is_port(Socket) ->
    ready_exit(State);
handle_info({'EXIT', Socket, _Reason}, full, State) when is_port(Socket) ->
    full_exit(State);
handle_info({'EXIT', Socket, _Reason}, reload, Reload) when is_port(Socket) ->
    reload_exit(Reload);
handle_info({'EXIT', _Pid, Reason}, _StateName, State) ->
    {stop, Reason, State};
handle_info({'DOWN', _MRef, _, Pid, Reason}, _StateName, State) ->
    {stop, {shutdown, {bad_creator, Pid, Reason}}, State}.

ready_exit(#state{locks=Locks} = State) ->
    {next_state, ready, State#state{locks=(Locks-1)}}.

full_exit(#state{config=#config{max_sockets=MaxSockets}, locks=MaxSockets,
                 waiters=[{Creator, MRef, HInfo} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef, HInfo),
    {next_state, full, State#state{waiters=Waiters}};
full_exit(#state{config=#config{max_sockets=MaxSockets}, locks=MaxSockets,
                 waiters=[{Creator, MRef} | Waiters]} = State) ->
    sd_creator:acquired(Creator, MRef),
    {next_state, full, State#state{waiters=Waiters}};
full_exit(#state{config=#config{max_sockets=MaxSockets},
                 locks=MaxSockets, waiters=[]} = State) ->
    {next_state, ready, State#state{locks=(MaxSockets-1)}};
full_exit(#state{locks=Locks} = State) ->
    {next_state, full, State#state{locks=(Locks-1)}}.

reload_exit(#reload{state_name=ready, state=State} = Reload) ->
    {next_state, ready, State2} = ready_exit(State),
    {next_state, reload, Reload#reload{state=State2}};
reload_exit(#reload{state_name=full, state=State} = Reload) ->
    case full_exit(State) of
        {next_state, ready, State2} ->
            {next_state, reload, Reload#reload{state_name=ready, state=State2}};
        {next_state, full, State2} ->
            {next_state, reload, Reload#reload{state=State2}}
    end.

code_change(_OldVsn, ready,
            #state{config=#config{mod=Mod, args=Args} = Config,
                   locks=Locks} = State, _Extra) ->
    case catch Mod:init(Args) of
        {ok, infinity} ->
            {ok, ready, #state{config=Config#config{max_sockets=infinity}}};
        {ok, MaxSockets}
          when is_integer(MaxSockets) andalso MaxSockets > Locks ->
            {ok, ready, #state{config=Config#config{max_sockets=MaxSockets}}};
        {ok, MaxSockets} when is_integer(MaxSockets) andalso MaxSockets >= 0 ->
            {ok, full, #state{config=Config#config{max_sockets=MaxSockets}}};
        ignore ->
            {ok, ready, State};
        {'EXIT', Reason} ->
            {error, Reason};
        Other ->
            {error, {bad_return, {Mod, init, Other}}}
    end;
code_change(_OldVsn, full,
            #state{config=#config{mod=Mod, args=Args}} = State, _Extra) ->
    case catch Mod:init(Args) of
        {ok, infinity} ->
            full_code_change(infinity, State);
        {ok, MaxSockets} when is_integer(MaxSockets) andalso MaxSockets >= 0 ->
            full_code_change(MaxSockets, State);
        ignore ->
            {ok, full, State};
        {'EXIT', Reason} ->
            {error, Reason};
        Other ->
            {error, {bad_return, {Mod, init, Other}}}
    end;
code_change(OldVsn, reload, #reload{state_name=StateName, state=State} = Reload,
            Extra) ->
    case code_change(OldVsn, StateName, State, Extra) of
        {ok, StateName2, State2} ->
            {ok, reload, Reload#reload{state_name=StateName2, state=State2}};
        {error, _Reason} = Error ->
            Error
    end.

full_code_change(MaxSockets,
                 #state{config=#config{max_sockets=OldMaxSockets} = Config,
                        locks=Locks, waiters=Waiters} = State)
  when MaxSockets > OldMaxSockets ->
    {Locks2, Waiters2} = acquired_waiters(MaxSockets, Locks, Waiters),
    Config2 = Config#config{max_sockets=MaxSockets},
    State2 = State#state{config=Config2, locks=Locks2, waiters=Waiters2},
    case Locks2 of
        MaxSockets ->
            {ok, full, State2};
        _Other ->
            {ok, ready, State2}
    end;
full_code_change(MaxSockets, #state{config=Config} = State) ->
    {ok, full, State#state{config=Config#config{max_sockets=MaxSockets}}}.

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

format_status(normal, [_PDict, #state{} = State]) ->
    [{data, [{"StateData", format_state(State)}]}];
format_status(normal, [_PDict, #reload{} = Reload]) ->
    [{data, [{"StateData", format_reload(Reload)}]}];
format_status(terminate, [_PDict, #state{} = State]) ->
    format_state(State);
format_status(terminate, [_PDict, #reload{} = Reload]) ->
    format_reload(Reload).

format_state(#state{config=#config{creators=Creators} = Config,
                    waiters=Waiters} = State) ->
    CKeys = record_info(fields, config),
    Creators2 = {gb_sets:size(Creators), gb_sets:to_list(Creators)},
    [config | CValues] = tuple_to_list(Config#config{creators=Creators2}),
    CList = lists:zip(CKeys, CValues),
    SKeys = record_info(fields, state),
    State2 = State#state{config=CList, waiters={length(Waiters), Waiters}},
    [state | SValues] = tuple_to_list(State2),
    lists:zip(SKeys, SValues).

format_reload(#reload{state=#state{} = State, old=Old} = Reload) ->
    SList = format_state(State),
    RKeys = record_info(fields, reload),
    Old2 = {gb_sets:size(Old), gb_sets:to_list(Old)},
    [reload | RValues] = tuple_to_list(Reload#reload{state=SList, old=Old2}),
    lists:zip(RKeys, RValues).

terminate(_Reason, _StateName, _State) ->
    ok.
