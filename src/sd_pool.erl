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
-module(sd_pool).

-behaviour(supervisor).

%% public api

-export([start_link/8]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link(Id, RRef, PRef, Manager, Socket, Watcher, Creator, Handler) ->
    {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      RRef :: reference(),
      PRef :: reference(),
      Manager :: pid(),
      Socket :: term(),
      Watcher :: supervisor:child_spec(),
      Creator :: supervisor:child_spec(),
      Handler :: supervisor:child_spec(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, RRef, PRef, Manager, Socket, Watcher, Creator, Handler) ->
    Name = {via, sd_reg, {Id, {?MODULE, {RRef, PRef}}}},
    Args = {Id, PRef, Manager, Socket, Watcher, Creator, Handler},
    supervisor:start_link(Name, ?MODULE, Args).

%% supervisor api

init({Id, PRef, Manager, Socket, Watcher, Creator, Handler}) ->
    HandlerSuper = {sd_handler_supersup,
                    {sd_handler_supersup, start_link, [Id, PRef, Handler]},
                    permanent, infinity, supervisor, [sd_handler_supersup]},
    Creator2 = sd_util:append_args(Creator, [PRef]),
    CreatorSup = {sd_creator_sup,
                  {sd_creator_sup, start_link, [Id, PRef, Creator2]},
                  permanent, infinity, supervisor, [sd_creator_sup]},
    Watcher2 = sd_util:append_args(Watcher, [PRef, Manager, Socket]),
    {ok, {{rest_for_one, 0, 1}, [HandlerSuper, CreatorSup, Watcher2]}}.
