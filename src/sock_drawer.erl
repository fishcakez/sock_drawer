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
-module(sock_drawer).

-behaviour(supervisor).

%% public api

-export([start_link/3]).
-export([start_link/4]).
-export([purge/1]).
-export([id/1]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([format_status/2]).
-export([terminate/2]).

%% types

-type sup_name() :: {pid(), module()} | {local, atom()} | {global, term()} |
                    {via, module(), term()}.
-type id() :: {sup_name(), reference()}.

-record(config, {id :: id(),
                 sock_info :: {module(), accept | connect, term()},
                 size :: non_neg_integer(),
                 intensity :: non_neg_integer(),
                 period :: non_neg_integer()}).

-record(state, {id :: id(),
                mod :: module(),
                reloader_ref :: reference(),
                sup :: term()}).

%% callbacks

-callback init(Args :: term()) ->
    {ok, {{{Family :: module(), Creation :: accept | connect, Target :: term()},
           Size :: non_neg_integer(), Intensity :: non_neg_integer(),
           Period :: non_neg_integer()},
          [ChildSpec :: supervisor:child_spec(), ...]}} | ignore.

%% public api

-spec start_link(Mod, Args, Opts) -> {ok, Pid} | {error, Reason} when
      Mod :: module(),
      Args :: term(),
      Opts :: list(),
      Pid :: pid(),
      Reason :: term().
start_link(Mod, Args, Opts) ->
    gen_server:start_link(?MODULE, {gen_server, self, Mod, Args}, Opts).


-spec start_link(Name, Mod, Args, Opts) -> {ok, Pid} | {error, Reason} when
      Name :: {local, atom()} | {global, term()} | {via, module(), term()},
      Mod :: module(),
      Args :: term(),
      Opts :: list(),
      Pid :: pid(),
      Reason :: term().
start_link(Name, Mod, Args, Opts) ->
    gen_server:start_link(?MODULE, {gen_server, Name, Mod, Args}, Opts).


-spec purge(Name) -> ok | {error, Reason} when
      Name :: pid() | atom() | {atom(), node()} | {global, term()} |
              {via, module(), term()},
      Reason :: term().
purge(Name) ->
    gen_server:call(Name, purge, infinity).

-spec id(Name) -> Id when
      Name :: pid() | atom() | {atom(), node()} | {global, term()} |
              {via, module(), term()},
      Id ::  id().
id(Name) ->
    gen_server:call(Name, id, infinity).

%% gen_server api

init({gen_server, self, Mod, Args}) ->
    init({gen_server, {self(), Mod}, Mod, Args});
init({gen_server, Name, Mod, Args}) ->
    _ = put('$initial_call', {Mod, init, 1}),
    Id = {Name, make_ref()},
    SupName = {via, sd_reg, {Id, ?MODULE}},
    SupArgs = {supervisor, Id, Mod, Args},
    case catch supervisor:init({SupName, ?MODULE, SupArgs}) of
        {ok, SupState} ->
            {[RRef], SupState2} = reloader_refs(SupState),
            {ok, #state{id=Id, mod=Mod, reloader_ref=RRef, sup=SupState2}};
        ignore ->
            ignore;
        {stop, _Reason} = Stop ->
            Stop;
        {'EXIT', Reason} ->
            {stop, Reason}
    end;
init({supervisor, Id, Mod, Args}) ->
    case catch Mod:init(Args) of
        {ok, {SupSpecs, ChildSpecs}} ->
            handle_init(Id, SupSpecs, ChildSpecs);
        ignore ->
            ignore;
        {'EXIT', Reason} ->
            exit(Reason);
        Other ->
            exit({bad_return, {Mod, init, Other}})
    end.

handle_call(purge, _From, #state{id=Id, sup=SupState} = State) ->
    case sup_call({start_child, purger(Id)}, SupState) of
        {reply, {ok, undefined}, SupState2} ->
            {reply, ok, State#state{sup=SupState2}};
        {reply, {error, _Reason} = Error, SupState2} ->
            {reply, Error, State#state{sup=SupState2}}
    end;
handle_call(id, _From, #state{id=Id} = State) ->
    {reply, Id, State};
handle_call(Request, From, #state{sup=SupState} = State) ->
    {reply, Reply, SupState} = supervisor:handle_call(Request, From, SupState),
    {reply, Reply, State#state{sup=SupState}}.

handle_cast({reload, RRef}, #state{reloader_ref=RRef, sup=SupState} = State) ->
    case sup_call({restart_child, {sd_reloader, RRef}}, SupState) of
        {reply, {ok, _Reloader}, SupState2} ->
            {noreply, State#state{sup=SupState2}};
        %% Failure during code_change, reloader already reloaded.
        {reply, {error, running}, SupState2} ->
            {noreply, State#state{sup=SupState2}};
        %% Failure during code_change, successful reload followed by failure.
        {reply, {error, restarting}, SupState2} ->
            {noreply, State#state{sup=SupState2}};
        %% not_found is not possible because RRef can't be known until after
        %% cast has been sent.
        {reply, {error, Reason}, SupState2} ->
            {stop, {reload_failed, Reason}, State#state{sup=SupState2}}
    end;
handle_cast({reload, _OldRRef}, State) ->
    {noreply, State};
handle_cast(Request, #state{sup=SupState} = State) ->
    case supervisor:handle_cast(Request, SupState) of
        {noreply, SupState2} ->
            {noreply, State#state{sup=SupState2}};
        {stop, Reason, SupState2} ->
            {stop, Reason, State#state{sup=SupState2}}
    end.

handle_info(Info, #state{sup=SupState} = State) ->
    case supervisor:handle_info(Info, SupState) of
        {noreply, SupState2} ->
            {noreply, State#state{sup=SupState2}};
        {stop, Reason, SupState2} ->
            {stop, Reason, State#state{sup=SupState2}}
    end.

code_change(OldVsn, #state{sup=SupState} = State, Extra) ->
    case supervisor:code_change(OldVsn, SupState, Extra) of
        {ok, SupState2} ->
            handle_code_change(State#state{sup=SupState2});
        Other ->
            Other
    end.

format_status(normal, [PDict, State]) ->
    {data, [{"State", format_state(PDict, State)}]};
format_status(terminate, [PDict, State]) ->
    format_state(PDict, State).

terminate(Reason, #state{id=Id, sup=SupState}) ->
    _ = sd_closer:start_link(Id),
    supervisor:terminate(Reason, SupState).

%% gen_server internal

sup_call(Request, SupState) ->
    From = {self(), {fake, make_ref()}},
    supervisor:handle_call(Request, From, SupState).

purger(Id) ->
    {sd_purger, {sd_purger, start_link, [Id]},
     temporary, 5000, worker, [sd_purger]}.

handle_code_change(#state{reloader_ref=OldRRef, sup=SupState} = State) ->
    SupState2 = remove_reloader(OldRRef, SupState),
    {[RRef], SupState3} = reloader_refs(SupState2),
    gen_server:cast(self(), {reload, RRef}),
    {ok, State#state{reloader_ref=RRef, sup=SupState3}}.

reloader_refs(SupState) ->
    {reply, Children, SupState2} = sup_call(which_children, SupState),
    SelectRRefs = fun({{sd_reloader, RRef}, _Pid, _Type, _Mods}) ->
                          {true, RRef};
                     (_Other) ->
                          false
                  end,
    {lists:filtermap(SelectRRefs, Children), SupState2}.

remove_reloader(RRef, SupState) ->
    Child = {sd_reloader, RRef},
    {reply, _, SupState2} = sup_call({terminate_child, Child}, SupState),
    {reply, _, SupState3} = sup_call({delete_child, Child}, SupState2),
    SupState3.

format_state(_PDict, #state{id=Id, mod=Mod, reloader_ref=RRef, sup=SupState}) ->
    [{id, Id}, {module, Mod}, {reloader_ref, RRef},
     {supervisor_state, SupState}].

%% supervisor internal

handle_init(Id, SupSpecs, ChildSpecs) ->
    try init_state(Id, SupSpecs) of
        #config{intensity=I, period=P} = State ->
            Children = init_children(State, ChildSpecs),
            {ok, {{rest_for_one, I, P}, Children}}
    catch
        throw:Reason ->
            exit({supervisor_data, Reason})
    end.

init_state(Id, {{Family, Creation, Target}, Size, I, P}) ->
    init_state(Id, Family, Creation, Target, Size, I, P);
init_state(_Id, Other) ->
    throw({invalid_type, Other}).

init_state(_, Family, _, _, _, _, _) when not is_atom(Family) ->
    throw({invalid_family, Family});
init_state(_, _, Creation, _, _,  _, _)
  when Creation =/= accept andalso Creation =/= connect ->
    throw({invalid_creation, Creation});
init_state(_, _, _, _, Size,  _, _)
  when not (is_integer(Size) andalso Size >= 0) ->
    throw({invalid_size, Size});
init_state(Id, Family, Creation, Target, Size, I, P) ->
    #config{id=Id, sock_info={Family, Creation, Target}, size=Size, intensity=I,
           period=P}.

init_children(State, ChildSpecs) ->
    try parse_children(State, ChildSpecs) of
        ChildSpecs2 ->
            ChildSpecs3 = [watcher(State) | ChildSpecs2],
            [agent(State), manager_sup(State), pool_sup(State),
             targeter_sup(State), reloader(State, ChildSpecs3)]
    catch
        throw:Reason ->
            exit({start_spec, Reason})
    end.

watcher(#config{id=Id, size=Size}) ->
    {sd_watcher, {sd_watcher, start_link, [Size, Id]},
     permanent, 5000, worker, [sd_watcher]}.

agent(#config{id=Id, sock_info=SockInfo}) ->
    {{sd_agent, Id},
     {sd_agent, start_link, [Id, SockInfo]},
     permanent, 5000, worker, [sd_agent]}.

manager_sup(#config{id=Id}) ->
    {sd_manager_sup, {sd_manager_sup, start_link, [Id]},
     permanent, infinity, supervisor, [sd_manager_sup]}.

pool_sup(#config{id=Id}) ->
    {sd_pool_sup, {sd_pool_sup, start_link, [Id]},
     permanent, infinity, supervisor, [sd_pool_sup]}.

targeter_sup(#config{id=Id}) ->
    {sd_targeter_sup, {sd_targeter_sup, start_link, [Id]},
     permanent, infinity, supervisor, [sd_targeter_sup]}.

reloader(#config{id=Id}, ChildSpecs) ->
    RRef = make_ref(),
    {{sd_reloader, RRef}, {sd_reloader, start_link, [Id, RRef | ChildSpecs]},
     permanent, 5000, worker, [sd_reloader]}.

parse_children(State, ChildSpecs) ->
    Fold = fun(Child, ChildSpecs2) ->
                   check_child(Child, State, ChildSpecs2)
           end,
    ChildSpecs3 = lists:foldl(Fold, [], ChildSpecs),
    sort_children(ChildSpecs3).

check_child(Child, State, ChildSpecs) ->
    case supervisor:check_childspecs([Child]) of
        ok ->
            add_child(Child, State, ChildSpecs);
        {error, Reason} ->
            throw(Reason)
    end.

add_child(Child, State, ChildSpecs) ->
    Id = element(1, Child),
    case lists:keymember(Id, 1, ChildSpecs) of
        true ->
            throw({duplicate_child_name, Id});
        false ->
            [update_child(Child, State) | ChildSpecs]
    end.

%% manager
update_child({manager, _MFA, permanent, _Shutdown, _Type, _Mods} = Manager,
             #config{id=Id}) ->
    sd_util:append_args(Manager, [Id]);
update_child({manager, _, _, Restart, _}, _) ->
    throw({invalid_manager_restart, Restart});
%% targeter
update_child({targeter, {M, F, Args}, permanent, Shutdown, Type, Mods},
             #config{id=Id, sock_info=SockInfo}) ->
    Args2 = Args ++ [SockInfo, Id],
    Mods2 = add_family_mod(SockInfo, Mods),
    {targeter, {M, F, Args2}, permanent, Shutdown, Type, Mods2};
update_child({targeter, _, _, Restart, _}, _) ->
    throw({invalid_targeter_restart, Restart});
%% creator
update_child({creator, {M, F, Args}, transient, Shutdown, Type, Mods},
             #config{id=Id, sock_info=SockInfo}) ->
    Args2 = Args ++ [SockInfo, Id],
    Mods2 = add_family_mod(SockInfo, Mods),
    {creator, {M, F, Args2}, transient, Shutdown, Type, Mods2};
update_child({creator, _, _, Restart, _}, _) ->
    throw({invalid_creator_restart, Restart});
%% handler
update_child({handler, {M, F, Args}, temporary, Shutdown, Type, Mods},
             #config{id=Id, sock_info=SockInfo}) ->
    Args2 = Args ++ [SockInfo, Id],
    Mods2 = add_family_mod(SockInfo, Mods),
    {handler, {M, F, Args2}, temporary, Shutdown, Type, Mods2};
update_child({handler, _, _, Restart, _}, _) ->
    throw({invalid_handler_restart, Restart});
%% other
update_child({Id, _, _, _, _}, _State) ->
    throw({invalid_name, Id}).

add_family_mod(_SockInfo, dynamic) ->
    dynamic;
add_family_mod({Family, _Creation, _Target}, Mods) ->
    case lists:member(Family, Mods) of
        true  -> Mods;
        false -> [Family | Mods]
    end.

sort_children(ChildSpecs) ->
    Fold = fun(Id, Acc) ->
                   [find_child(Id, ChildSpecs) | Acc]
           end,
    Ids = [manager, targeter, creator, handler],
    try lists:foldl(Fold, [], Ids) of
        ChildSpecs2 ->
            lists:reverse(ChildSpecs2)
    catch
        throw:Reason ->
            exit({start_spec, Reason})
    end.

find_child(Id, ChildSpecs) ->
    case lists:keyfind(Id, 1, ChildSpecs) of
        false ->
            throw({missing_child_name, Id});
        Child ->
            Child
    end.
