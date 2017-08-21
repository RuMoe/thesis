% @copyright 2012-2016 Zuse Institute Berlin,

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
%   limitations under the License.

%% @author Florian Schintke <schintke@zib.de>
%% @doc    Generic paxos round based register (prbr) implementation.
%%         The read/write store alias acceptor.
%% @end
%% @version $Id$
-module(prbr).
-author('schintke@zib.de').
-vsn('$Id:$ ').

%-define(TRACE(X,Y), io:format(X,Y)).
-define(TRACE(X,Y), ok).
-include("scalaris.hrl").

-define(FAST_WRITE, config:read(prbr_enable_fast_write)).

-define(PDB, db_prbr).
-define(REPAIR, config:read(prbr_repair_on_write)).
-define(REPAIR_DELAY, 100). % in ms
-define(REDUNDANCY, config:read(redundancy_module)).

-define(CSET_SIZE_SOFT_CAP, config:read(prbr_cset_size_soft_cap)).

%%% the prbr has to be embedded into a gen_component using it.
%%% The state it operates on has to be passed to the on handler
%%% correctly. All messages it handles start with the token
%%% prbr to support a generic, embeddable on-handler trigger.

%%% functions for module where embedded into
-export([on/2, init/1, close/1, close_and_delete/1]).
-export([check_config/0]).
-export([noop_read_filter/1]).  %% See rbrcseq for explanation.
-export([noop_write_filter/3]). %% See rbrcseq for explanation.
-export([new/2]).
-export([set_entry/2]).
-export([get_entry/2]).
-export([delete_entry/2]).
-export([entry_key/1]).
-export([entry_val/1]).
-export([entry_set_val/2]).

-export([tester_create_write_filter/1]).

%% let fetch the number of DB entries
-export([get_load/1]).

%% only for unittests
-export([tab2list_raw_unittest/1]).

%% only during recover
-export([tab2list/1]).

-export_type([message/0]).
-export_type([state/0]).
-export_type([read_filter/0]).
-export_type([write_filter/0]).
-export_type([entry/0]).

%% read_filter(custom_data() | no_value_yet) -> read_info()
-type read_filter() :: fun((term()) -> term()).

%% write_filter(OldLocalDBentry :: custom_data(),
%%              InfosToUpdateOutdatedEntry :: info_passed_from_read_to_write(),
%%              ValueForWriteOperation:: Value())
%% -> {custom_data(), value_returned_to_caller()}
-type write_filter() :: fun((term(), term(), term()) -> {term(), term()}).

-type state() :: ?PDB:db().

-type message() ::
        {prbr, read, DB :: dht_node_state:db_selector(),
         WasConsistentLookup :: boolean(),
         Proposer :: comm:mypid(), ?RT:key(), DataType :: module(),
         InRound :: pr:pr(),
         read_filter()}
      | {prbr, write, DB :: dht_node_state:db_selector(),
         WasConsistentLookup :: boolean(),
         Proposer :: comm:mypid(), ?RT:key(), DataType :: module(),
         InRound :: pr:pr(), Value :: term(), PassedToUpdate :: term(),
         write_filter()}
      | {prbr, delete_key, DB :: dht_node_state:db_selector(),
         Client :: comm:mypid(), Key :: ?RT:key()}
      | {prbr, tab2list_raw, DB :: dht_node_state:db_selector(),
         Client :: comm:mypid()}.


%% improvements to usual paxos:

%% for reads the client has just to send a unique identifier and the
%% acceptor provides a valid round number. The actual round number of
%% the request is then the tuple {round_number, unique_id}.

%% A proposer then may receive answers with different round numbers
%% and selects that one with the highest round, where he also takes
%% the value from.

%% on read the acceptor can assign the next round number. They remain
%% unique as we get the node_id in the read request and that is part of
%% the round number.

%% so there are no longer any read denies, all reads succeed.
-type entry() :: { any(), %% key
                   pr:pr(), %% r_read
                   pr:pr(), %% r_write
                   any(), %% value
                   cset:class(), %% last equivalence class seen in read
                   cset:cset(), %% current set of commuting commands in progress
                   cset:cset()  %% the previous cset
                 }.

%% Messages to expect from this module
-spec msg_round_request_reply(comm:mypid(), boolean(), pr:pr(), pr:pr(),
                              any(), cset:cset(), cset:cset()) -> ok.
msg_round_request_reply(Client, Cons, ReadRound, WriteRound, Value, CSet, PrevCSet) ->
    comm:send(Client, {round_request_reply, Cons,  ReadRound, WriteRound, Value, CSet, PrevCSet}).

-spec msg_read_reply(comm:mypid(), Consistency::boolean(), pr:pr(), atom(),
                     any(), cset:cset(), cset:cset()) -> ok.
msg_read_reply(Client, Cons, YourRound, Val, LastWriteRound, CSet, PrevCSet) ->
    comm:send(Client, {read_reply, Cons, YourRound, Val, LastWriteRound, CSet, PrevCSet}).

-spec msg_read_deny(comm:mypid(), Consistency::boolean(), pr:pr(), pr:pr()) -> ok.
msg_read_deny(Client, Cons, YourRound, LargerRound) ->
    comm:send(Client, {read_deny, Cons, YourRound, LargerRound}).

-spec msg_write_reply(comm:mypid(), Consistency::boolean(),
                      any(), pr:pr(), pr:pr(), any()) -> ok.
msg_write_reply(Client, Cons, Key, UsedWriteRound, YourNextRoundForWrite, WriteRet) ->
    comm:send(Client, {write_reply, Cons, Key, UsedWriteRound, YourNextRoundForWrite, WriteRet}).

-spec msg_write_deny(comm:mypid(), Consistency::boolean(), any(), pr:pr())
                    -> ok.
msg_write_deny(Client, Cons, Key, WriteRoundTried) ->
    comm:send(Client, {write_deny, Cons, Key, WriteRoundTried}).

-spec noop_read_filter(term()) -> term().
noop_read_filter(X) -> X.

-spec noop_write_filter(Old :: term(), UpdateInfo :: term(), Val :: term()) -> {term(), term()}.
noop_write_filter(_, UI, X) -> {X, UI}.

%% initialize: return initial state.
-spec init(atom() | tuple()) -> state().
init(DBName) -> ?PDB:new(DBName).

%% @doc Closes the given DB (it may be recoverable using open/1 depending on
%%      the DB back-end).
-spec close(state()) -> true.
close(State) -> ?PDB:close(State).

%% @doc Closes the given DB and deletes all contents (this DB can thus not be
%%      re-opened using open/1).
-spec close_and_delete(state()) -> true.
close_and_delete(State) -> ?PDB:close_and_delete(State).

-spec on(message(), state()) -> state().
on({prbr, round_request, _DB, Cons, Proposer, Key, DataType, ProposerUID, ReadFilter, CmdClass}, TableName) ->
    ?TRACE("prbr:round_request: ~p in round ~p~n", [Key, ProposerUID]),
    KeyEntry = get_entry(Key, TableName),

    %% custom prbr read handler might change value (e.g. due to GCing)
    {NewKeyEntryVal, ReadVal, ValueHasChanged} =
        case erlang:function_exported(DataType, prbr_read_handler, 3) of
            true -> DataType:prbr_read_handler(KeyEntry, TableName, ReadFilter);
            _    -> {entry_val(KeyEntry), ReadFilter(entry_val(KeyEntry)), false}
        end,

    %% Check if the current command interferes with the last seen command.
    %% A read never interferes with another command. If the current command
    %% belongs to the same class, it means that they commute and thus not interfere.
    %% Expection: Checkpoints interfere with all other commands.
    %% Interference is not symmetric: In-progress reads do not interfere with
    %% checkpoints, but in-progress checkpoints interfere with reads
    LastReadClass = entry_cmd_class_read(KeyEntry),
    CurrentCSetSize = cset:size(entry_cset(KeyEntry)),
    ReadClass = cset:read_class(),
    CheckpointClass = cset:non_commuting_class(),
    IsInterfering = case CmdClass of
                        CheckpointClass -> true;
                        ReadClass -> false;
                        LastReadClass ->
                            %% CSets grow linear in size when processing commuting
                            %% commands. Since unrestricted growth causes trouble,
                            %% we need to set a limit.
                            %% Pretend this write is interfering if the limit is reached
                            SizeLimitReached = CurrentCSetSize >= ?CSET_SIZE_SOFT_CAP,
                            %% If read round is greater than write round (it cannot be smaller),
                            %% then this request will always start a new cset. Therefore, the
                            %% size restriction of the current cset does not apply
                            SameCSet = pr:get_r(entry_r_read(KeyEntry)) =:=
                                        pr:get_r(entry_r_write(KeyEntry)),

                            SameCSet andalso SizeLimitReached;
                        _ -> true
                    end,

    %% Assign a valid next read round number
    %% Do not increment it if there is no command interference.
    %% This prevents concurrent, but commuting commands form
    %% interfering with each other, since the proposer will receive
    %% consistent read rounds from all replicas.
    AssignedReadRound =
        case not IsInterfering  of
            true ->
                OldRound = entry_r_read(KeyEntry),
                pr:new(pr:get_r(OldRound), ProposerUID);
            _ ->
                next_read_round(KeyEntry, ProposerUID)
        end,
    trace_mpath:log_info(self(), {'prbr:on(round_request)',
                                  %% key, Key,
                                  round, AssignedReadRound,
                                  val, NewKeyEntryVal,
                                  read_filter, ReadFilter}),

    msg_round_request_reply(Proposer, Cons, AssignedReadRound, entry_r_write(KeyEntry),
                            ReadVal, entry_cset(KeyEntry), entry_prev_cset(KeyEntry)),

    _ = case not IsInterfering andalso not ValueHasChanged of
        true ->
            %% No updates must be performed; save a DB write operation
            %% (Above, the proposer UID of the read round is changed even
            %% for a read. The new round must be returned to the client since
            %% it contains the request id for the round_request, but it does
            %% not have to be stored in DB since there are no follow-up requests
            %% in a read and reads do not interfere with other ops)
            ok;
        false ->
            NewKeyEntry = entry_set_r_read(KeyEntry, AssignedReadRound),
            NewKeyEntry2 = entry_set_val(NewKeyEntry, NewKeyEntryVal),
            NewKeyEntry3 = entry_set_cmd_class_read(NewKeyEntry2, CmdClass),
            set_entry(NewKeyEntry3, TableName)
    end,

    TableName;

on({prbr, read, _DB, Cons, Proposer, Key, DataType, ProposerUID, ReadFilter,
   ReadRound, CmdClass}, TableName) ->
    ?TRACE("prbr:read: ~p in round ~p~n", [Key, ReadRound]),
    KeyEntry = get_entry(Key, TableName),

    _ = case pr:get_r(ReadRound) > pr:get_r(entry_r_read(KeyEntry)) of
         true ->
             %% prbr read handler might change value (e.g. due to GCing)
            {NewKeyEntryVal, ReadVal, _ValueHasChanged} =
                case erlang:function_exported(DataType, prbr_read_handler, 3) of
                    true -> DataType:prbr_read_handler(KeyEntry, TableName, ReadFilter);
                    _    -> {entry_val(KeyEntry), ReadFilter(entry_val(KeyEntry)), false}
                end,
            trace_mpath:log_info(self(), {'prbr:on(read)',
                                          %% key, Key,
                                          round, ReadRound,
                                          val, NewKeyEntryVal,
                                          read_filter, ReadFilter}),

            EntryWriteRound = entry_r_write(KeyEntry),
            % A prbr read has a different request ID than the previously executed
            % round_request, and therefore a different ProposerUID.
            NewReadRound = pr:new(pr:get_r(ReadRound), ProposerUID),

            msg_read_reply(Proposer, Cons, NewReadRound, ReadVal, EntryWriteRound,
                           entry_cset(KeyEntry), entry_prev_cset(KeyEntry)),

            NewKeyEntry = entry_set_r_read(KeyEntry, NewReadRound),
            NewKeyEntry2 = entry_set_val(NewKeyEntry, NewKeyEntryVal),
            NewKeyEntry3 = entry_set_cmd_class_read(NewKeyEntry2, CmdClass),
            _ = set_entry(NewKeyEntry3, TableName);
         _ ->
            msg_read_deny(Proposer, Cons, ReadRound, entry_r_read(KeyEntry))
    end,
    TableName;

%% TODO fix fast_write? write must deliver prev_cmd_id information etc, client must store that
%% TODO do only store needed cmd infos when writing checkpoint here
on({prbr, write, DB, Cons, Proposer, Key, CmdClass, DataType, ProposerUID, InRound,
    PrevCSet, Value, PassedToUpdate, WriteFilter, IsWriteThrough}, TableName) ->

    ?TRACE("prbr:write for key: ~p in round ~n~p~n", [Key, InRound]),
    trace_mpath:log_info(self(), {prbr_on_write}),
    KeyEntry = get_entry(Key, TableName),

    _ = case writable(KeyEntry, CmdClass, InRound, PrevCSet, IsWriteThrough) of
            commute ->
                %% This write commutes with the previous write command. In contrast
                %% to the previous write, do not start a new cset. Instead append this cmd
                %% to the current cset.
                {NewVal, Ret} =
                    case erlang:function_exported(DataType, prbr_write_handler, 5) of
                        true ->
                            DataType:prbr_write_handler(KeyEntry, PassedToUpdate,
                                                        Value, TableName, WriteFilter);
                        _    ->
                            WriteFilter(entry_val(KeyEntry), PassedToUpdate, Value)
                    end,

                NewWriteRound = pr:new(pr:get_r(InRound), ProposerUID),
                TEntry = entry_set_r_write(KeyEntry, NewWriteRound),

                %% extend current cset
                CurrentCSet = entry_cset(TEntry),
                ThisCmdId = {Proposer, Ret},
                ThisCmd = cset:new_command(ThisCmdId, WriteFilter, PassedToUpdate, Value),
                NewCSet = cset:add(ThisCmd, CurrentCSet),
                NewEntry = entry_set_cset(TEntry, NewCSet),

                trace_mpath:log_info(self(), {'prbr:on(write)',
                                              round, NewWriteRound,
                                              passed_to_update, PassedToUpdate,
                                              val, Value,
                                              write_filter, WriteFilter,
                                              newval, NewVal}),

                msg_write_reply(Proposer, Cons, Key, NewWriteRound,
                                  entry_r_read(NewEntry), Ret),

                set_entry(entry_set_val(NewEntry, NewVal), TableName);
            true ->
                %% Start of a new CSet

                %%%% apply the current operation
                {NewVal, Ret} =
                    case erlang:function_exported(DataType, prbr_write_handler, 5) of
                        true ->
                            DataType:prbr_write_handler(KeyEntry, PassedToUpdate,
                                                        Value, TableName, WriteFilter);
                        _    ->
                            WriteFilter(entry_val(KeyEntry), PassedToUpdate, Value)
                    end,

                %%%% update rounds
                NewWriteRound = pr:new(pr:get_r(InRound), ProposerUID),
                T1Entry = entry_set_r_write(KeyEntry, NewWriteRound),

                NewReadRound =
                    case ?FAST_WRITE of
                        true ->
                            %% prepare for fast write
                            next_read_round(NewWriteRound, ProposerUID);
                        _ ->
                            NewWriteRound
                    end,
                T2Entry = entry_set_r_read(NewWriteRound, NewReadRound),

                %%%% construct the new cset
                {ThisCmdId, LearnerToNotify} =
                    case IsWriteThrough of
                        true ->
                            %% TODO: explain
                            CmdId = lists:flatten(cset:cmd_id_list(PrevCSet)),
                            {CmdId, [{Proposer, Ret} | CmdId]};
                        _ ->
                            CmdId = {Proposer, Ret},
                            {CmdId, [CmdId]}
                    end,
                T3Entry = entry_set_prev_cset(T2Entry, PrevCSet),
                NewCSet = cset:new(CmdClass, pr:get_r(InRound)),
                NewCmd = cset:new_command(ThisCmdId, WriteFilter, PassedToUpdate, Value),
                NewEntry = entry_set_cset(T3Entry, cset:add(NewCmd, NewCSet)),

                %%%% finish works
                trace_mpath:log_info(self(), {'prbr:on(write)',
                                              round, NewWriteRound,
                                              passed_to_update, PassedToUpdate,
                                              val, Value,
                                              write_filter, WriteFilter,
                                              newval, NewVal}),
                [msg_write_reply(P, Cons, Key, NewWriteRound,
                                  NewReadRound, R)
                 || {P, R} <- LearnerToNotify],

                set_entry(entry_set_val(NewEntry, NewVal), TableName);
            {false, Reason} ->
                RoundTried = pr:new(pr:get_r(InRound), ProposerUID),
                trace_mpath:log_info(self(), {'prbr:on(write) denied',
                                              round, RoundTried}),

                case Reason of
                    repair_required ->
                        %% Start repair on write
                        ?TRACE("Initiating on-write repair for entry~n~p", [KeyEntry]),
                        comm:send_local_after(?REPAIR_DELAY, self(),
                                              {prbr,
                                               init_repair_on_write,
                                               DB,
                                               entry_key(KeyEntry),
                                               entry_r_write(KeyEntry)}),
                        ok;
                    _ -> ok
                end,

                %% When the client recieves enough denies, it must completely restart
                %% its write, therefore it is not necessary to send any "newer round".
                %% The round the client used to write is send back, because the client
                %% must distinguish between denies from its own request and possible
                %% write through attempts based on its partially completed write.

                %% TODO: in writethrough, do original writes need to be informed?
                msg_write_deny(Proposer, Cons, Key, RoundTried)
        end,
    TableName;

on({prbr, init_repair_on_write, DB, Key, KnownWriteRound}, TableName) ->
    %% Triggers a repair process for this replica.
    %% The repair process will send a qread to retrieve the most recent rounds
    %% and value. This data will be used to refresh the replica under the condition
    %% that no other process has written on this replica in the meantime (because
    %% this is only possible if the most recent value was already established).
    KeyEntry = get_entry(Key, TableName),
    _ = case KnownWriteRound =:= entry_r_write(KeyEntry) of
          true ->
            ?TRACE("Starting read for on-write repair on key~n~p", [Key]),
            Envelope = {prbr, repair_on_write, DB, Key, KnownWriteRound, '_'},
            SendTo = comm:reply_as(self(), 6, Envelope),
            rbrcseq:qread(DB, SendTo, Key, prbr_on_use_repair);
          false -> ok
        end,
    TableName;

on({prbr, repair_on_write, _DB, Key, KnownWriteRound,
    {qread_done, _ReqId, ReadRound, WriteRound, Value}}, TableName) ->
    KeyEntry = get_entry(Key, TableName),
    _ = case KnownWriteRound =:= entry_r_write(KeyEntry) of
            true ->
                %% Change only if this replica was not modified yet
                ?TRACE("On-write repair of replica on key ~n~p", [Key]),
                KeyEntry2 = entry_set_r_read(KeyEntry, ReadRound),
                KeyEntry3 = entry_set_r_write(KeyEntry2, WriteRound),
                KeyEntry4 = entry_set_val(KeyEntry3, Value),
                _ = set_entry(KeyEntry4, TableName);
            false -> ok
        end,
    TableName;

on({prbr, delete_key, _DB, Client, Key}, TableName) ->
    %% for normal delete we will have to have a special write operation taking
    %% the Paxos round numbers into account...
    ?ASSERT(util:is_unittest()), % may only be used in unit-tests
    ct:pal("R~p deleted~n", [?RT:get_key_segment(Key)]),
    Entry = get_entry(Key, TableName),
    _ = delete_entry(TableName, Entry),
    comm:send_local(Client, {delete_key_reply, Key}),
    TableName;

on({prbr, get_entry, _DB, Client, Key}, TableName) ->
    comm:send_local(Client, {entry, get_entry(Key, TableName)}),
    TableName;

on({prbr, tab2list_raw, DB, Client}, TableName) ->
    comm:send_local(Client, {DB, tab2list_raw(TableName)}),
    TableName.

-spec get_entry(any(), state()) -> entry().
get_entry(Id, TableName) ->
    case ?PDB:get(TableName, Id) of
        {}    -> new(Id);
        Entry -> Entry
    end.

-spec set_entry(entry(), state()) -> state().
set_entry(NewEntry, TableName) ->
    _ = ?PDB:set(TableName, NewEntry),
    TableName.

-spec delete_entry(state(), entry()) -> db_prbr:db().
delete_entry(TableName, Entry) ->
    ?PDB:delete_entry(TableName, Entry).

-spec get_load(state()) -> non_neg_integer().
get_load(State) -> ?PDB:get_load(State).

-spec tab2list(state()) -> [{any(),any()}].
tab2list(State) ->
    %% without prbr own data
    Entries = tab2list_raw(State),
    [ {entry_key(X), entry_val(X)} || X <- Entries].

-spec tab2list_raw_unittest(state()) -> [entry()].
tab2list_raw_unittest(State) ->
    ?ASSERT(util:is_unittest()), % may only be used in unit-tests
    tab2list_raw(State).

-spec tab2list_raw(state()) -> [entry()].
tab2list_raw(State) ->
    %% with prbr own data
    ?PDB:tab2list(State).

%% operations for abstract data type entry()

-spec new(any()) -> entry().
new(Key) ->
    new(Key, prbr_bottom).

-spec new(any(), any()) -> entry().
new(Key, Val) ->
    {Key,
     %% Note: atoms < pids, so this is a good default.
     _R_Read = pr:new(0, '_'),
     %% Note: atoms < pids, so this is a good default.
     _R_Write = pr:new(0, '_'),
     _Value = Val,
     _CmdClass = cset:non_commuting_class(),
     _CSet = cset:new(cset:non_commuting_class(), 0),
     _PrevCmdIds = []
     }.

-spec entry_key(entry()) -> any().
entry_key(Entry) -> element(1, Entry).
%% -spec entry_set_key(entry(), any()) -> entry().
%% entry_set_key(Entry, Key) -> setelement(2, Entry, Key).
-spec entry_r_read(entry()) -> pr:pr().
entry_r_read(Entry) -> element(2, Entry).
-spec entry_set_r_read(entry(), pr:pr()) -> entry().
entry_set_r_read(Entry, Round) -> setelement(2, Entry, Round).

-spec entry_r_write(entry()) -> pr:pr().
entry_r_write(Entry) -> element(3, Entry).
-spec entry_set_r_write(entry(), pr:pr()) -> entry().
entry_set_r_write(Entry, Round) -> setelement(3, Entry, Round).

-spec entry_val(entry()) -> any().
entry_val(Entry) -> element(4, Entry).
-spec entry_set_val(entry(), any()) -> entry().
entry_set_val(Entry, Value) -> setelement(4, Entry, Value).

-spec entry_cmd_class_read(entry()) -> cset:class().
entry_cmd_class_read(Entry) -> element(5, Entry).
-spec entry_set_cmd_class_read(entry(), cset:class()) -> entry().
entry_set_cmd_class_read(Entry, Class) -> setelement(5, Entry, Class).

-spec entry_set_cset(entry(), cset:cset()) -> entry().
entry_set_cset(Entry, CSet) -> setelement(6, Entry, CSet).
-spec entry_cset(entry()) -> cset:cset().
entry_cset(Entry) -> element(6, Entry).

-spec entry_prev_cset(entry()) -> cset:cset().
entry_prev_cset(Entry) -> element(7, Entry).
-spec entry_set_prev_cset(entry(), [any()]) -> entry().
entry_set_prev_cset(Entry, CSetId) -> setelement(7, Entry, CSetId).


-spec next_read_round(entry(), any()) -> pr:pr().
next_read_round(Entry, ProposerUID) ->
    LatestSeenRead = pr:get_r(entry_r_read(Entry)),
    LatestSeenWrite = pr:get_r(entry_r_write(Entry)),
    pr:new(util:max(LatestSeenRead, LatestSeenWrite) + 1, ProposerUID).


-spec writable(entry(), cset:class(), pr:pr(), cset:cset(), prbr:write_filter()) ->
          true | commute | {false, repair_required | denied}.
writable(Entry, CmdClass, InRound, PrevCSet, IsWriteThrough) ->
    CurrentCSet = entry_cset(Entry),
    CurrentCmdClass = cset:get_class(entry_cset(Entry)),
    LatestSeenRead = entry_r_read(Entry),
    LatestSeenWrite = entry_r_write(Entry),
    InRoundR = pr:get_r(InRound),
    LatestSeenReadR = pr:get_r(LatestSeenRead),
    LatestSeenWriteR = pr:get_r(LatestSeenWrite),

    %% make sure that no write filter operations are missing in the
    %% sequence of writes
    GaplessWriteSequence = IsWriteThrough orelse
                               (cset:get_class(PrevCSet) =:= cset:get_class(CurrentCSet) andalso
                                    cset:get_round(PrevCSet) =:= cset:get_round(CurrentCSet) andalso
                                    %% this replica is not allowed to have cmds that were not seen
                                    %% in the read quorum
                                    cset:size(cset:subtract(CurrentCSet, PrevCSet)) =:= 0),

    IsCommutingClass = CmdClass =:= CurrentCmdClass andalso
                           CmdClass =/= cset:non_commuting_class(),

    if IsCommutingClass andalso
       InRoundR =:= LatestSeenReadR andalso
       InRoundR =:= LatestSeenWriteR ->
            %% This write commutes with the last write on this replica.
            %% Since the round numbers are also identical, no non-commuting
            %% write has read this replica yet.
            commute;
       InRoundR >= LatestSeenReadR andalso
       InRoundR > LatestSeenWriteR andalso
       GaplessWriteSequence ->

            true;
       true ->
            %% If this replica is empty due to node failure, and
            %% therefore lags behind other replicas, a repair process
            %% can be started which will send a qread to the other
            %% replicas to refresh its rounds and value.
            RepairRequired = ?REPAIR
                                andalso ?REDUNDANCY =:= replication
                                andalso not GaplessWriteSequence
                                andalso LatestSeenWriteR =:= 0,
            Reason = case RepairRequired of
                        true -> repair_required;
                        false -> denied
                     end,
            {false, Reason}
    end.

%% @doc Checks whether config parameters exist and are valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_atom(redundancy_module) andalso
        config:cfg_is_bool(prbr_repair_on_write) andalso
        config:cfg_is_integer(prbr_cset_size_soft_cap).

-spec tester_create_write_filter(0) -> write_filter().
tester_create_write_filter(0) -> fun prbr:noop_write_filter/3.

