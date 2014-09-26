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
-module(sd_targeter).

-behaviour(gen_fsm).

%% public api

-export([start_link/4]).

%% gen_fsm api

-export([init/1]).
-export([listening/2]).
-export([listening/3]).
-export([seeking/2]).
-export([seeking/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([format_status/2]).
-export([terminate/3]).

%% types

-record(state, {id, family, target, opts, timeout, socket}).

%% public api

start_link(Opts, Timeout, SockInfo, Id) ->
    gen_fsm:start_link({via, sd_reg, {Id, ?MODULE}}, ?MODULE,
                       {Id, SockInfo, Opts, Timeout}, []).

%% gen_fsm api

init({Id, {Family, accept, Target}, Opts, Timeout}) ->
    process_flag(trap_exit, true),
    case listen(Family, Target, Opts, 1, Timeout) of
        {ok, LSocket} ->
            sd_agent:store(Id, socket, LSocket),
            {ok, listening, #state{id=Id, family=Family, target=Target,
                                   opts=Opts, timeout=Timeout, socket=LSocket}};
        {error, Reason} ->
            {stop, Reason}
    end;
init({Id, {Family, connect, Target}, Opts, Timeout}) ->
    process_flag(trap_exit, true),
    case Family:getaddrs(Target, Timeout) of
        {ok, _Addrs} ->
            SSocket = sd_seek:new(Target, Opts),
            sd_agent:store(Id, socket, SSocket),
            {ok, seeking, #state{id=Id, family=Family, target=Target,
                                 opts=Opts, timeout=Timeout, socket=SSocket},
             5000};
        {error, Reason} ->
            {stop, Reason}
    end.

listening(Event, State) ->
    {stop, {bad_event, Event}, State}.

listening(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

seeking(timeout, #state{family=Family, target=Target,
                        timeout=Timeout} = State) ->
    case Family:getaddrs(Target, Timeout) of
        {ok, _Addrs} ->
            {next_state, seeking, State, 5000};
        {error, Reason} ->
            {stop, {socket_getaaddrs, Reason}, State}
    end.

seeking(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

handle_event(Event, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_sync_event(Event, _From, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_info({'EXIT', _, Reason}, _StateName, State) ->
    {stop, Reason, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

format_status(normal, [_PDict, #state{} = State]) ->
    [{data, [{"StateData", format_state(State)}]}];
format_status(terminate, [_PDict, #state{} = State]) ->
    format_state(State).

format_state(#state{} = State) ->
    SKeys = record_info(fields, state),
    [state | SValues] = tuple_to_list(State),
    lists:zip(SKeys, SValues).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(_Reason, listening, #state{family=Family, socket=LSocket}) ->
    ok = Family:close(LSocket);
terminate(_Reason, seeking, #state{socket=SSocket}) ->
    ok = sd_seek:close(SSocket).

%% internal

listen(Family, Target, Opts, Backoff, Timeout) ->
    case Family:listen(Target, Opts) of
        {ok, _LSocket} = Result ->
            Result;
        {error, eaddrinuse} when Timeout > 0 ->
            Backoff2 = min(Backoff * 2, min(200, Timeout)),
            timer:sleep(Backoff),
            listen(Family, Target, Opts, Backoff2, Timeout - Backoff2);
        {error, _Reason} = Error ->
            Error
    end.
