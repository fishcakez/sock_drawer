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
-module(sdt_rand_manager).

-behaviour(sock_drawer).

%% public api

-export([start_link/2]).

%% sock_drawer api

-export([init/1]).

%% public api

-spec start_link(Creation, Port) -> {ok, Pid} | {error, Reason} when
      Creation :: accept | connect,
      Port :: inet:port_number(),
      Pid :: pid(),
      Reason :: term().
start_link(Creation, Port) ->
    sock_drawer:start_link(?MODULE, {Creation, Port}, []).

%% sock_drawer api

init({Creation, Port}) ->
    %% Default seed: 5, 6.
    MaxSockets = 2 + random:uniform(5),
    Manager = {manager, {sdt_simple, start_link, [MaxSockets]},
               permanent, 5000, worker, [sdt_simple, sd_simple]},
    Targeter = {targeter, {sd_targeter, start_link, [[], 1000]},
                permanent, 5000, worker, [sd_targeter]},
    Creator = {creator,
               {sd_creator, start_link, [[{packet, 4}], 1000, {0,0}, {0,0}]},
               transient, 5000, worker, [sd_creator]},
    Handler = {handler, {sdt_handler, start_link, []},
               temporary, 5000, worker, [sdt_handler]},
    {ok, {{{sd_tcp, Creation, {{127,0,0,1}, Port}}, 5, 1, 5},
           [Manager, Targeter, Creator, Handler]}}.
