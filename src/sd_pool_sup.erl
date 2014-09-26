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
-module(sd_pool_sup).

-behaviour(supervisor).

%% public api

-export([start_link/1]).
-export([start_pool/7]).
-export([terminate_pools/1]).
-export([terminate_pool/2]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link(Id) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      Pid :: pid(),
      Reason :: term().
start_link(Id) ->
    supervisor:start_link({via, sd_reg, {Id, ?MODULE}}, ?MODULE, Id).

-spec start_pool(Id, RRef, PRef, Socket, Watcher, Creator, Handler) ->
    {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      RRef :: reference(),
      PRef :: reference(),
      Socket :: term(),
      Watcher :: supervisor:child_spec(),
      Creator :: supervisor:child_spec(),
      Handler :: supervisor:child_spec(),
      Pid :: pid(),
      Reason :: term().
start_pool(Id, RRef, PRef, Socket, Watcher, Creator, Handler) ->
    Args = [RRef, PRef, Socket, Watcher, Creator, Handler],
    supervisor:start_child({via, sd_reg, {Id, ?MODULE}}, Args).

-spec terminate_pools(Id) -> ok when
      Id :: sock_drawer:id().
terminate_pools(Id) ->
    Sup = {via, sd_reg, {Id, ?MODULE}},
    Pools = supervisor:which_children(Sup),
    _ = [supervisor:terminate_child(Sup, Pool) ||
         {_Id, Pool, _Type, _Mods} <- Pools],
    ok.

-spec terminate_pool(Id, Pool) -> ok | {error, not_found} when
      Id :: sock_drawer:id(),
      Pool :: pid().
terminate_pool(Id, Pool) ->
    supervisor:terminate_child({via, sd_reg, {Id, ?MODULE}}, Pool).

%% supervisor api

init(Id) ->
    Pool = {pool, {sd_pool, start_link, [Id]}, permanent, infinity,
            supervisor, [sd_pool]},
    {ok, {{simple_one_for_one, 0, 1}, [Pool]}}.
