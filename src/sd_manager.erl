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
-module(sd_manager).

%% public api

-export([which_creators/1]).

%% creator api

-export([acquire/3]).
-export([release/2]).
-export([leave/3]).

%% watcher api

-export([join/3]).

%% public api

-spec which_creators(Id) -> [Creator] when
      Id :: sock_drawer:id(),
      Creator :: pid().
which_creators(Id) ->
    gen_fsm:sync_send_event({via, sd_reg, {Id, ?MODULE}}, which_creators).

%% creator api

-spec acquire(Manager, PRef, MRef) -> ok when
      Manager :: pid(),
      PRef :: reference(),
      MRef :: reference().
acquire(Manager, PRef, MRef) ->
    gen_fsm:send_event(Manager, {acquire, PRef, self(), MRef}).

-spec release(Manager, PRef) -> ok when
      Manager :: pid(),
      PRef :: reference().
release(Manager, PRef) ->
    gen_fsm:sync_send_event(Manager, {release, PRef}).

-spec leave(Manager, PRef, MRef) -> ok when
      Manager :: pid(),
      PRef :: reference(),
      MRef :: reference().
leave(Manager, PRef, MRef) ->
    gen_fsm:sync_send_event(Manager, {leave, PRef, self(), MRef}).

%% watcher api

-spec join(Id, PRef, Creators) ->
    {ok, ARef} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      Creators :: [pid()],
      ARef :: reference(),
      Reason :: term().
join(Id, PRef, Creators) ->
    case sd_reg:whereis_name({Id, ?MODULE}) of
        Manager when is_pid(Manager) ->
            ARef = monitor(process, Manager),
            Event = {join, PRef, self(), ARef, Creators},
            case gen_fsm:sync_send_event(Manager, Event) of
                {ok, ARef} = OK ->
                    OK;
                {error, _Reason} = Error ->
                    Error
            end;
        undefined ->
            {error, not_found}
    end.
