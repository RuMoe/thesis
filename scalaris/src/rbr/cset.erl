% @copyright 2017 Zuse Institute Berlin,

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License

%% @author Jan Skrzypczak <skrzypczak@zib.de>
%% @doc    Abstraction for sets of commuting operations
%%         This module operates under the assumption that
%%         the relation 'commute' (||) is an equivalence relation.
%%         (It is reflexive, symmetric, transitiv).
%% @end
%% @version $Id$
%% TODO Better module description
%%
-module(cset).
-author('skrzypczak@zib.de').
-vsn('$Id:$ ').

-define(TRACE(X,Y), ok).
-define(CID(X), element(1, X)).

-include("scalaris.hrl").

-export_type([class/0, command/0, cset/0]).

-export([new/2, new_command/4]).
-export([size/1]).

-export([equals/2]).
-export([add/2]).
-export([union/1, union/2]).
-export([subtract/2]).

-export([apply_all/2]).

-export([wf_list/1]).
-export([cmd_id_list/1]).
-export([get_class/1]).
-export([get_round/1]).

-export([get_cmd_id/1]).
-export([get_cmd_wf/1]).
-export([get_cmd_ui/1]).
-export([get_cmd_wval/1]).

-export([non_commuting_class/0]).
-export([read_class/0]).

-type class() :: atom(). %% equivalence class id

-type cset() :: {class(), non_neg_integer(), [command()]}. %% commands are sorted by id

-type command() :: {
                    CommandId :: any(),
                    WriteFilter :: prbr:write_filter(),
                    UpdateInfo :: any(),
                    WriteValue :: any()
                   }.

%%@doc Creates a new empty CSet
-spec new(class(), non_neg_integer()) -> cset().
new(CSetClass, Round) -> {CSetClass, Round, []}.

%%@doc Creates a new command
-spec new_command(any(), prbr:write_filter(), any(), any()) -> command().
new_command(CommandId, WriteFilter, UpdateInfo, WriteValue) ->
    {CommandId, WriteFilter, UpdateInfo, WriteValue}.

%%@doc Returns the number of commands of a cset
-spec size(cset()) -> non_neg_integer().
size(_CSet={_Class, _, Cmds}) -> length(Cmds).

%%@doc Checks two CSets/Command lists for equality
-spec equals(cset(), cset()) -> boolean();
            ([command()], [command()]) -> boolean().
equals(_CSet1={Class, R, Cmds1},_CSet2={Class, R, Cmds2}) -> equals(Cmds1, Cmds2);
equals([H1|T1], [H2|T2]) when ?CID(H1) =:= ?CID(H2) -> equals(T1, T2);
equals([], []) -> true;
equals(_, _) -> false.

%%@doc Adds a command to a CSet. If a command with the same ID already
%% exists, nothing happens
-spec add(command(), cset()) -> cset().
add(Cmd, _CSet={Class, R, CmdList}) -> {Class, R, add1(Cmd, CmdList)}.

%%Helper of add/2
-spec add1(command(), [command()]) -> [command()].
add1(Cmd, [H|T]) when ?CID(Cmd) > ?CID(H) -> [H | add1(Cmd, T)];
add1(Cmd, L=[H|_]) when ?CID(Cmd) < ?CID(H) -> [Cmd | L];
add1(_Cmd, L=[_H|_]) -> L; %% Cmd_id =:= H_id
add1(Cmd, []) -> [Cmd].

%%@doc Union of list of CSets
-spec union([cset()]) -> cset().
union([CSet1, CSet2 | CSetList]) -> union([union(CSet1, CSet2) | CSetList]);
union([CSet]) -> CSet.

%%@doc Union of two CSets. Both CSets must have the same class
-spec union(cset(), cset()) -> cset().
union(_CSet1={C, R, Cmds1}, _CSet2={C, R, Cmds2}) -> {C, R, union1(Cmds1, Cmds2)}.

%% Helper of union/2
-spec union1([command()], [command()]) -> [command()].
union1([C1|T1], L2=[C2|_]) when ?CID(C1) < ?CID(C2) -> [C1 | union1(T1, L2)];
union1(L1=[C1|_], [C2|T2]) when ?CID(C1) > ?CID(C2) -> [C2 | union1(T2, L1)];
union1([C1|T1], [_C2|T2]) -> [C1 | union1(T1, T2)];  %% C1_id =:= C2_id
union1([], L2) -> L2;
union1(L1, []) -> L1.

%%@doc Subtract CSet2 from CSet1. Both CSets must have the same class
-spec subtract(cset(), cset()) -> cset().
subtract(_CSet1={C, R, Cmds1}, _CSet2={C, R, Cmds2}) -> {C, R, subtract1(Cmds1, Cmds2)}.

%% Helper of subtrac/2
-spec subtract1([command()], [command()]) -> [command()].
subtract1([C1|T1], L2=[C2|_]) when ?CID(C1) < ?CID(C2) -> [C1|subtract1(T1,L2)];
subtract1(L1=[C1|_], [C2|T2]) when ?CID(C1) > ?CID(C2) -> subtract1(L1,T2);
subtract1([_C1|T1], [_C2|T2]) -> subtract1(T1, T2);
subtract1([], _L2) -> [];
subtract1(L1, []) -> L1.

%%@doc Applies all commands contained in CSet to Value.
-spec apply_all(cset(), any()) -> any().
apply_all(_CSet={_, _, Cmds}, Value) -> apply1(Cmds, Value).

%% Helper of apply_all/2
apply1([{_Id,WF,UI,WV}|T], Value) ->
    %% WF returns tuple {ValueToWriteToDB, ValueToPassToClient}
    %% only the first element is relevant
    apply1(T, element(1, WF(Value, UI, WV)));
apply1([], Value) -> Value.

%%@doc Returns the CSet 'class' signaling write commuting with no other
%% command.
-spec non_commuting_class() -> class().
non_commuting_class() -> checkpoint.

%%@doc Returns the CSet class for read commands.
-spec read_class() -> class().
read_class() -> read.

%%@doc Returns all write filter containd in the given cset
-spec wf_list(cset()) -> [prbr:write_filter()].
wf_list(_CSet={_Class, _, Cmds}) -> [get_cmd_wf(C) || C <- Cmds].

-spec cmd_id_list(cset()) -> [any()].
cmd_id_list(_CSet={_Class, _, Cmds}) -> [get_cmd_id(C) || C <- Cmds].

-spec get_class(cset()) -> class().
get_class(CSet) -> element(1, CSet).
-spec get_round(cset()) -> non_neg_integer().
get_round(CSet) -> element(2, CSet).

-spec get_cmd_id(command()) -> any().
get_cmd_id(Cmd) -> ?CID(Cmd).
-spec get_cmd_wf(command()) -> prbr:write_filter().
get_cmd_wf(Cmd) -> element(2, Cmd).
-spec get_cmd_ui(command()) -> any().
get_cmd_ui(Cmd) -> element(3, Cmd).
-spec get_cmd_wval(command()) -> any().
get_cmd_wval(Cmd) -> element(4, Cmd).

