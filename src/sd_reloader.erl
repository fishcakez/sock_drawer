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
-module(sd_reloader).

%% public api

-export([start_link/7]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

%% types

-record(specs, {manager, targeter, watcher, creator, handler}).
-record(state, {id, ref, specs}).

%% public api

-spec start_link(Id, RRef, Watcher, Manager, Targeter, Creator, Handler) ->
    {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      RRef :: reference(),
      Watcher :: supervisor:child_spec(),
      Manager :: supervisor:child_spec(),
      Targeter :: supervisor:child_spec(),
      Creator :: supervisor:child_spec(),
      Handler :: supervisor:child_spec(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, RRef, Watcher, Manager, Targeter, Creator, Handler) ->
    ChildSpecs = {Watcher, Manager, Targeter, Creator, Handler},
    gen_server:start_link({via, sd_reg, {Id, {?MODULE, RRef}}}, ?MODULE,
                          {Id, RRef, ChildSpecs}, []).

%% gen_server api

init({Id, RRef, {Watcher, Manager, Targeter, Creator, Handler}}) ->
    Specs = #specs{manager=Manager, targeter=Targeter, watcher=Watcher,
                   creator=Creator, handler=Handler},
    State = #state{id=Id, ref=RRef, specs=Specs},
    case handle_reload(State) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_reload(#state{id=Id, ref=RRef, specs=Specs}) ->
    check_manager(Id, RRef, Specs).

check_manager(Id, RRef, #specs{manager=Manager} = Specs) ->
    case sd_agent:find(Id, manager) of
        {ok, Manager} ->
            ensure_manager(Id, RRef, Specs);
        _Other ->
            reload_manager(Id, RRef, Specs)
    end.

ensure_manager(Id, RRef, #specs{manager=Manager} = Specs) ->
    case sd_manager_sup:start_manager(Id, Manager) of
        {ok, _Pid} ->
            check_targeter(Id, RRef, Specs);
        {ok, _Pid, _Info} ->
            check_targeter(Id, RRef, Specs);
        {error, {already_started, _Pid}} ->
            check_targeter(Id, RRef, Specs);
        {error, already_present = Reason} ->
            failed_to_start_child(manager, Reason);
        {error, {Reason, _Child}} ->
            failed_to_start_child(manager, Reason)
    end.

failed_to_start_child(Child, Reason) ->
    {error, {shutdown, {failed_to_start_child, Child, Reason}}}.

reload_manager(Id, RRef, Specs) ->
    case stop_manager(Id) of
        ok ->
            start_manager(Id, RRef, Specs);
        {error, _Reason} = Error ->
            Error
    end.

stop_manager(Id) ->
    % Closes targeter and creators belonging to manager
    case sd_closer:start_link(Id) of
        ignore ->
            ok = sd_pool_sup:terminate_pools(Id),
            ok = sd_manager_sup:terminate_manager(Id);
        {error, _Reason} = Error ->
            Error
    end.

start_manager(Id, RRef, #specs{manager=Manager} = Specs) ->
    sd_agent:erase(Id, manager),
    case sd_manager_sup:start_manager(Id, Manager) of
        {ok, _Pid} ->
            sd_agent:store(Id, manager, Manager),
            start_targeter(Id, RRef, Specs);
        {ok, _Pid, _Info} ->
            sd_agent:store(Id, manager, Manager),
            start_targeter(Id, RRef, Specs);
        {error, {already_started, _Pid} = Reason} ->
            failed_to_start_child(manager, Reason);
        {error, already_present = Reason} ->
            failed_to_start_child(manager, Reason);
        {error, {Reason, _Child}} ->
            failed_to_start_child(manager, Reason)
    end.

check_targeter(Id, RRef, #specs{targeter=Targeter} = Specs) ->
    case sd_agent:find(Id, targeter) of
        {ok, Targeter} ->
            ensure_targeter(Id, RRef, Specs);
        _Other ->
            reload_targeter(Id, RRef, Specs)
    end.

ensure_targeter(Id, RRef, #specs{targeter=Targeter} = Specs) ->
    case sd_targeter_sup:start_targeter(Id, Targeter) of
        {ok, _Pid} ->
            start_pool(Id, RRef, Specs);
        {ok, _Pid, _Info} ->
            start_pool(Id, RRef, Specs);
        {error, {already_started, _Pid}} ->
            start_pool(Id, RRef, Specs);
        {error, already_present = Reason} ->
            failed_to_start_child(targeter, Reason);
        {error, {Reason, _Child}} ->
            failed_to_start_child(targeter, Reason)
    end.

reload_targeter(Id, RRef, Specs) ->
    ok = stop_targeter(Id),
    start_targeter(Id, RRef, Specs).

stop_targeter(Id) ->
    ok = sd_targeter_sup:terminate_targeter(Id).

start_targeter(Id, RRef, #specs{targeter=Targeter} = Specs) ->
    sd_agent:erase(Id, targeter),
    case sd_targeter_sup:start_targeter(Id, Targeter) of
        {ok, _Pid} ->
            sd_agent:store(Id, targeter, Targeter),
            start_pool(Id, RRef, Specs);
        {ok, _Pid, _Info} ->
            sd_agent:store(Id, targeter, Targeter),
            start_pool(Id, RRef, Specs);
        {error, {already_started, _Pid} = Reason} ->
            failed_to_start_child(targeter, Reason);
        {error, already_present = Reason} ->
            failed_to_start_child(targeter, Reason);
        {error, {Reason, _Child}} ->
            failed_to_start_child(targeter, Reason)
    end.

start_pool(Id, RRef, #specs{watcher=Watcher, creator=Creator,
                            handler=Handler}) ->
    PRef = make_ref(),
    {ok, Socket} = sd_agent:find(Id, socket),
    case sd_pool_sup:start_pool(Id, RRef, PRef, Socket, Watcher, Creator,
                                Handler) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, {already_started, _Pid} = Reason} ->
            failed_to_start_child(sd_pool, Reason);
        {error, already_present = Reason} ->
            failed_to_start_child(sd_pool, Reason);
        {error, {Reason, _Child}} ->
            failed_to_start_child(sd_pool, Reason)
    end.

handle_call(Request, _From, State) ->
    {stop, {bad_call, Request}, State}.

handle_cast(Request, State) ->
    {stop, {bad_cast, Request}, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
