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
-module(sd_creators).

%% public api

-export([new/0]).
-export([join/4]).
-export([leave/1]).
-export([leave/2]).
-export([left/2]).

%% types

-type creators() :: gb_sets:set({pid(), reference()}).

%% public api

-spec new() -> Creators when
      Creators :: creators().
new() ->
    gb_sets:new().

-spec join(Creators, PRef, MaxSockets, Locks) -> {Locks2, Waiters, New} when
      Creators :: [pid()],
      PRef :: reference(),
      MaxSockets :: non_neg_integer() | infinity,
      Locks :: non_neg_integer(),
      Locks2 :: non_neg_integer(),
      Waiters :: [{pid(), reference()}],
      New :: creators().
join(Creators, PRef, MaxSockets, Locks) when MaxSockets > Locks ->
    join_acquire(Creators, PRef, MaxSockets, Locks, gb_sets:new());
join(Creators, PRef, _MaxSockets, Locks) ->
    {Waiters, New} = join_wait(Creators, PRef, [], gb_sets:new()),
    {Locks, Waiters, New}.

join_acquire([], _PRef, _MaxSockets, Locks, New) ->
    {Locks, [], New};
join_acquire(Creators, PRef, MaxSockets, MaxSockets, New) ->
    {Waiters, New2} = join_wait(Creators, PRef, [], New),
    {MaxSockets, Waiters, New2};
join_acquire([Creator | Creators], PRef, MaxSockets, Locks, New) ->
    MRef = monitor(process, Creator),
    sd_creator:join_acquired(Creator, PRef, MRef),
    New2 = gb_sets:insert({Creator, MRef}, New),
    join_acquire(Creators, PRef, MaxSockets, Locks+1, New2).

join_wait([], _PRef, Waiters, New) ->
    {Waiters, New};
join_wait([Creator | Creators], PRef, Waiters, New) ->
    MRef = monitor(process, Creator),
    sd_creator:join_wait(Creator, PRef, MRef),
    Elem = {Creator, MRef},
    New2 = gb_sets:insert(Elem, New),
    join_wait(Creators, PRef, [Elem | Waiters], New2).

-spec leave(Old) -> ok when
      Old :: creators().
leave(Old) ->
    Leave = fun({Creator, MRef}, Acc) ->
                    sd_creator:leave(Creator, MRef),
                    Acc
            end,
    gb_sets:fold(Leave, ok, Old).

-spec leave(Waiters, Old) -> Old2 when
      Waiters :: [{pid(), reference()} |{pid(), reference(), term()}],
      Old :: creators(),
      Old2 :: creators().
leave([], Old) ->
    Old;
leave([{Creator, MRef, HInfo} | Waiters], Old) ->
    sd_creator:leave(Creator, MRef, HInfo),
    leave(Waiters, gb_sets:delete({Creator, MRef}, Old));
leave([{Creator, MRef} = Elem | Waiters], Old) ->
    sd_creator:leave(Creator, MRef),
    leave(Waiters, gb_sets:delete(Elem, Old)).

-spec left({Creator, MRef}, Creators) -> Creators2 when
      Creator :: pid(),
      MRef :: reference(),
      Creators :: creators(),
      Creators2 :: creators().
left({_Creator, MRef} = Elem, Creators) ->
    demonitor(MRef, [flush]),
    gb_sets:delete(Elem, Creators).
