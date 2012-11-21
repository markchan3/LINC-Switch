%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc Module for handling all group related tasks.

-module(linc_us3_groups).

%% Group routing
%%-export([apply/2]).

%% API as defined by LINC team
-export([create/0
         , destroy/0
         , apply/2
         , modify/1
         , get_stats/1
         , get_desc/1
         , get_features/1
         , update_reference_count/2]).

%% Group Mod
%% -export([add/1,
%%          modify/1,
%%          delete/1]).

-include("linc_us3.hrl").
%% already included from linc_us3.hrl -include_lib("of_protocol/include/ofp_v3.hrl").

-type linc_bucket_id() :: {integer(), binary()}.

%% @doc Bucket wrapper adding unique_id field to the original OFP bucket
-record(linc_bucket, {
          bucket    :: ofp_bucket(),
          unique_id :: linc_bucket_id()
         }).

%% @doc Group object
-record(linc_group, {
          id               :: ofp_group_id(),
          type    = all    :: ofp_group_type(),
          total_weight = 0 :: integer(),
          buckets = []     :: [#linc_bucket{}]
         }).

%% @doc Stats item record for storing stats in ETS
-record(linc_group_stats, {
          key   :: {group, integer(), atom()} | {bucket, {integer(), binary()}, atom()},
          value :: integer()
         }).

%%%==============================================================
%%% API implementation
%%%==============================================================

%% @doc Module startup
create() ->
    group_table = ets:new(group_table, [named_table, public,
                                        {keypos, #linc_group.id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    %% Stats are stored in form of #linc_group_stats{key, value}, key is a tuple
    %% {group, GroupId, packet_count}
    %% {group, GroupId, byte_count}
    %% {bucket, GroupId, BucketId, packet_count}
    %% {bucket, GroupId, BucketId, byte_count}
    %% and value is 32 or 64 bit unsigned counter, which wraps when reaching max
    %% value for 32 or 64 bit.
    group_stats = ets:new(group_stats, [named_table, public,
                                        {keypos, #linc_group_stats.key},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    ok.

%%--------------------------------------------------------------------
%% @doc Module shutdown
destroy() ->
    ets:delete(group_table),
    ets:delete(group_stats),
    ok.

%%--------------------------------------------------------------------
%% @doc Modifies group reference count by Increment
%% NOTE: will not wrap to 0xFFFFFFFF if accidentaly went below zero, the
%% counter will remain negative, but will wrap if overflows 32bit
update_reference_count(GroupId, Increment) ->
    group_update_stats(GroupId, reference_count, Increment).

%%--------------------------------------------------------------------
%% @doc Applies group GroupId to packet Pkt, result should be list of
%% packets and ports where they are destined or 'drop' atom. Packet is
%% cloned if multiple ports are the destination.
-spec apply(GroupId :: integer(), Pkt :: #ofs_pkt{}) -> ok.
                   %% [{NewPkt :: #ofs_pkt{}, Port :: ofp_port_no() | drop}].

apply(GroupId, Pkt) ->
    case group_get(GroupId) of
        not_found -> ok;
        Group     ->
            %% update group stats
            group_update_stats(GroupId, packet_count, 1),
            group_update_stats(GroupId, byte_count, Pkt#ofs_pkt.size),

            apply_group_type_to_packet(Group, Pkt)
    end.

%%--------------------------------------------------------------------
-spec modify(#ofp_group_mod{}) -> ok | {error, Type :: atom(), Code :: atom()}.
modify(#ofp_group_mod{ command = add,
                       group_id = Id,
                       type = Type,
                       buckets = Buckets }) ->
    %% Add new entry to the group table, if entry with given group id is already
    %% present, then return error.
    OFSBuckets = wrap_buckets_into_linc_buckets(Id, Buckets),
    Entry = #linc_group{
               id = Id,
               type = Type,
               buckets = OFSBuckets,
               total_weight = calculate_total_weight(Buckets)
              },
    case ets:insert_new(group_table, Entry) of
        true ->
            %% just in case, zero stats
            group_reset_stats(Id);
        false ->
            {error, #ofp_error_msg{type = group_mod_failed,
                                   code = group_exists}}
    end;

modify(#ofp_group_mod{ command = modify,
                       group_id = Id,
                       type = Type,
                       buckets = Buckets }) ->
    %% Modify existing entry in the group table, if entry with given group id
    %% is not in the table, then return error.
    Entry = #linc_group{
               id = Id,
               type = Type,
               buckets = Buckets,
               total_weight = calculate_total_weight(Buckets)
              },
    %% Reset group counters
    %% Delete stats for buckets
    case group_get(Id) of
        not_found ->
            {error, #ofp_error_msg{type = group_mod_failed,
                                   code = unknown_group}};
        Group ->
            [group_reset_bucket_stats(B#linc_bucket.unique_id)
             || B <- Group#linc_group.buckets],

            case ets:member(group_table, Id) of
                true ->
                    ets:insert(group_table, Entry),
                    ok;
                false ->
                    {error, #ofp_error_msg{type = group_mod_failed,
                                           code = unknown_group}}
            end
    end;

modify(#ofp_group_mod{ command = delete,
                       group_id = Id }) ->
    %% Deletes existing entry in the group table, if entry with given group id
    %% is not in the table, no error is recorded. Flows containing given
    %% group id are removed along with it.
    %% If one wishes to effectively delete a group yet leave in flow entries
    %% using it, that group can be cleared by sending a modify with no buckets
    %% specified.
    case Id of
        all ->
            %% Reset group counters
            ets:delete_all_objects(group_table),
            ets:delete_all_objects(group_stats);
        any ->
            %% TODO: Should we support this case at all?
            ok;
        Id ->
            group_reset_stats(Id),
            ets:delete(group_table, Id)
    end,
    %% TODO: Remove flows containing given group along with it
    ok.

%%--------------------------------------------------------------------
%% @doc Responds with stats for given group or special atom 'all' requests
%% stats for all groups in a list
%% Returns no error, if the requested id doesn't exist, would return empty list
-spec get_stats(#ofp_group_stats_request{}) ->
                       #ofp_group_stats_reply{}.
get_stats(R) ->
    %% Special groupid 'all' requests all groups stats
    case R#ofp_group_stats_request.group_id of
        all -> IdList = [];
        Id -> IdList = [Id]
    end,
    Stats = [group_get_stats(Id) || Id <- IdList],
    #ofp_group_stats_reply{ stats = lists:flatten(Stats) }.

%%--------------------------------------------------------------------
-spec get_desc(#ofp_group_desc_stats_request{}) ->
                      #ofp_group_desc_stats_reply{}.
get_desc(_R) ->
    #ofp_group_desc_stats_reply{
       stats = group_enum_groups()
      }.

%%--------------------------------------------------------------------
-spec get_features(#ofp_group_features_stats_request{}) ->
                          #ofp_group_features_stats_reply{}.
get_features(#ofp_group_features_stats_request{ flags = _F }) ->
    #ofp_group_features_stats_reply{
       types = [all, select, indirect, ff],
       capabilities = [select_weight, chaining], %select_liveness, chaining_checks
       max_groups = {?MAX, ?MAX, ?MAX, ?MAX},
       actions = {?SUPPORTED_WRITE_ACTIONS, ?SUPPORTED_WRITE_ACTIONS,
                  ?SUPPORTED_WRITE_ACTIONS, ?SUPPORTED_WRITE_ACTIONS}
      }.

%%%==============================================================
%%% Tool Functions
%%%==============================================================

%% @internal
%% @doc Chooses a bucket of actions from list of buckets according to the
%% group type. Executes actions. Returns [{packet, portnum|'drop'}]
%% (see 5.4.1 of OF1.2 spec)
-spec apply_group_type_to_packet(#linc_group{}, #ofs_pkt{}) -> ok.

apply_group_type_to_packet(#linc_group{type = all, buckets = Buckets},
                           Pkt = #ofs_pkt{}) ->
    %% Required: all: Execute all buckets in the group. This group is used for
    %% multicast or broadcast forwarding. The packet is effectively cloned for
    %% each bucket; one packet is processed for each bucket of the group. If a
    %% bucket directs a packet explicitly out of the ingress port, this packet
    %% clone is dropped. If the controller writer wants to forward out of the
    %% ingress port, the group should include an extra bucket which includes an
    %% output action to the OFPP_IN_PORT reseved port.
    lists:map(fun(Bucket) ->
                      apply_bucket(Bucket, Pkt)
              end, Buckets),
    ok;

apply_group_type_to_packet(G = #linc_group{type = select, buckets = Buckets},
                           Pkt = #ofs_pkt{}) ->
    %% Optional: select: Execute one bucket in the group. Packets are processed
    %% by a single bucket in the group, based on a switch-computed selection
    %% algorithm (e.g. hash on some user-configured tuple or simple round robin).
    %% All configuration and state for the selection algorithm is external to
    %% OpenFlow. The selection algorithm should implement equal load sharing and
    %% can optionally be based on bucket weights. When a port specified in a
    %% bucket in a select group goes down, the switch may restrict bucket
    %% selection to the remaining set (those with forwarding actions to live ports)
    %% instead of dropping packets destined to that port.

    Rand = random:uniform(G#linc_group.total_weight),
    Bucket = select_random_bucket_by_weight(Rand, 0, Buckets),

    %% check against empty bucket list
    true = (Bucket =/= not_found),
    ok = apply_bucket(Bucket, Pkt),
    ok;

apply_group_type_to_packet(#linc_group{type = indirect, buckets = Buckets},
                           Pkt = #ofs_pkt{})  ->
    %% Required: indirect: Execute the one defined bucket in this group. This
    %% group supports only a single bucket. Allows multiple flows or groups to
    %% point to a common group identifier, supporting faster, more efficient
    %% convergence (e.g. next hops for IP forwarding). This group type is
    %% effectively identical to an 'all' group with one bucket.
    [Bucket] = Buckets,
    ok = apply_bucket(Bucket, Pkt),
    ok;

apply_group_type_to_packet(#linc_group{type = ff, buckets = Buckets},
                           Pkt = #ofs_pkt{})  ->
    %% Optional: fast failover: Execute the first live bucket. Each action bucket
    %% is associated with a specific port and/or group that controls its liveness.
    %% The buckets are evaluated in the order defined by the group, and the first
    %% bucket which is associated with a live port/group is selected. This group
    %% type enables the switch to change forwarding without requiring a round
    %% trip to the controller. If no buckets are live, packets are dropped. This
    %% group type must implement a liveness mechanism (see 6.9 of OF1.2 spec)
    case pick_live_bucket(Buckets) of
        false -> 
            ok;
        Bucket ->
            ok = apply_bucket(Bucket, Pkt),
            ok      
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Select bucket based on port liveness logic
-spec pick_live_bucket([#linc_bucket{}]) -> #linc_bucket{} | false.

pick_live_bucket([]) -> false;
pick_live_bucket([Bucket | _]) -> Bucket.

%%--------------------------------------------------------------------
%% @internal
%% @doc Applies set of commands
-spec apply_bucket(#linc_bucket{}, #ofs_pkt{}) -> ok.

apply_bucket(#linc_bucket{
                unique_id = BucketId,
                bucket = #ofp_bucket{actions = Actions}
               }, Pkt) ->
    %% update bucket stats no matter where packet goes
    group_update_bucket_stats(BucketId, packet_count, 1),
    group_update_bucket_stats(BucketId, byte_count, Pkt#ofs_pkt.size),

    %%ActionsSet = ordsets:from_list(Actions),
    case linc_us3_actions:apply_set(Actions, Pkt) of
        {output, NewPkt, PortNo} ->
            linc_us3_port:send(NewPkt, PortNo);
        {group, NewPkt, GroupId} ->
            ?MODULE:apply(NewPkt, GroupId);
        drop ->
            drop
    end,
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Called from modify() to wrap incoming buckets into #linc_bucket{}, with
%% counters added, which is wrapped into #linc_bucket{} with unique id added
-spec wrap_buckets_into_linc_buckets(GroupId :: integer(),
                                     [#ofp_bucket{}]) -> [#linc_bucket{}].

wrap_buckets_into_linc_buckets(GroupId, Buckets) ->
    lists:map(fun(B) ->
                      #linc_bucket{
                         bucket = B,
                         unique_id = {GroupId, create_unique_id_for_bucket(B)}
                        }
              end, Buckets).

%%--------------------------------------------------------------------
%% @internal
%% @doc Creates an unique ID based on contents of the bucket. If contents changes,
%% the unique ID will be recalculated and changes as well.
-spec create_unique_id_for_bucket(#ofp_bucket{}) -> term().

create_unique_id_for_bucket(B) ->
    EncodedBucket = ofp_v3_encode:do(#ofp_message{version = 0, xid = 0, body = B}),

    %% Add a timestamp in case of identical buckets
    {MegaS, S, MicroS} = os:timestamp(),
    Image = <<EncodedBucket/binary, MegaS:32, S:32, MicroS:32>>,

    crypto:sha(Image).

%% create_unique_id_for_bucket(B) ->
%%     {MegaS, S, MicroS} = time:now(),
%%     MegaS * 1000000 * 1000000 + S * 1000000 + MicroS.

%%%==============================================================
%%% Stats counters and groups support functions
%%%==============================================================

%%--------------------------------------------------------------------
%% @internal
%% @doc Deletes all stats for group but not the buckets!
group_reset_stats(GroupId) ->
    %% Delete stats for group
    ets:delete(group_stats, {group, GroupId, reference_count}),
    ets:delete(group_stats, {group, GroupId, packet_count}),
    ets:delete(group_stats, {group, GroupId, byte_count}),
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Updates stat counter in ETS for group
-spec group_update_stats(GroupId :: integer(),
                         Stat :: atom(),
                         Increment :: integer()) -> ok.

group_update_stats(GroupId, Stat, Increment) ->
    Threshold = (1 bsl group_stat_bitsize(Stat)) - 1,
    try
        ets:update_counter(group_stats,
                           {group, GroupId, Stat},
                           {#linc_group_stats.value, Increment, Threshold, 0})
    catch
        error:badarg ->
            ets:insert(group_stats, #linc_group_stats{
                                       key = {group, GroupId, Stat},
                                       value = Increment
                                      })
    end,
    ok.


%%--------------------------------------------------------------------
%% @internal
%% @doc Requests full group stats
-spec group_get_stats(integer()) -> #ofp_group_stats{} | not_found.
group_get_stats(GroupId) ->
    case group_get(GroupId) of
        not_found ->
            [];
        G ->
            BStats = [#ofp_bucket_counter{
                         packet_count = group_get_bucket_stat(Bucket#linc_bucket.unique_id,
                                                              packet_count),
                         byte_count = group_get_bucket_stat(Bucket#linc_bucket.unique_id,
                                                            byte_count)
                        } || Bucket <- G#linc_group.buckets],
            [#ofp_group_stats{
                group_id = GroupId,
                ref_count = group_get_stat(GroupId, reference_count),
                packet_count = group_get_stat(GroupId, packet_count),
                byte_count = group_get_stat(GroupId, byte_count),
                bucket_stats = BStats
               }]
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Retrieves one stat for group, zero if stat or group doesn't exist
group_get_stat(GroupId, Stat) ->
    case ets:lookup(group_stats, {group, GroupId, Stat}) of
        []      -> 0;
        [{linc_group_stats, {group, GroupId, Stat}, Value}] -> Value
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Retrieves one stat for bucket (group id is part of bucket id),
%% returns zero if stat or group or bucket doesn't exist
group_get_bucket_stat(BucketId, Stat) ->
    case ets:lookup(group_stats, {bucket, BucketId, Stat}) of
        []      -> 0;
        [Value] -> Value
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Deletes bucket stats for groupid and bucketid
-spec group_reset_bucket_stats(linc_bucket_id()) -> ok.

group_reset_bucket_stats(BucketId) ->
    ets:delete(group_stats, {bucket, BucketId, packet_count}),
    ets:delete(group_stats, {bucket, BucketId, byte_count}),
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Updates stat counter in ETS for bucket in group
-spec group_update_bucket_stats(BucketId :: linc_bucket_id(),
                                Stat :: atom(),
                                Increment :: integer()) -> ok.

group_update_bucket_stats(BucketId, Stat, Increment) ->
    Threshold = (1 bsl group_bucket_stat_bitsize(Stat)) - 1,
    try
        ets:update_counter(group_stats,
                           {bucket, BucketId, Stat},
                           {#linc_group_stats.value, Increment, Threshold, 0})
    catch
        error:badarg ->
            ets:insert(group_stats, #linc_group_stats{
                                       key = {bucket, BucketId, Stat},
                                       value = Increment
                                      })
    end,
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Reads group from ETS or returns not_found
-spec group_get(integer()) -> not_found | #linc_group{}.

group_get(GroupId) ->
    case ets:lookup(group_table, GroupId) of
        [] -> not_found;
        [Group] -> Group
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Returns bit width of counter fields for group
group_stat_bitsize(reference_count) -> 32;
group_stat_bitsize(packet_count)    -> 64;
group_stat_bitsize(byte_count)      -> 64.
%group_stat_bitsize(X) ->
%    erlang:raise(exit, {badarg, X}).
    
%%--------------------------------------------------------------------
%% @internal
%% @doc Returns bit width of counter fields for bucket
group_bucket_stat_bitsize(packet_count) -> 64;
group_bucket_stat_bitsize(byte_count)   -> 64.
%group_bucket_stat_bitsize(X) ->
%    erlang:raise(exit, {badarg, X}).


%%--------------------------------------------------------------------
%% @internal
%% @doc Iterates over all keys of groups table and creates list of
%% #ofp_group_desc_stats{} standard records for group stats response
-spec group_enum_groups() -> [#ofp_group_desc_stats{}].
group_enum_groups() ->
    group_enum_groups_2(ets:first(group_table), []).

%% @internal
%% @hidden
%% @doc (does the iteration job for group_enum_groups/0)
group_enum_groups_2('$end_of_table', Accum) ->
    lists:reverse(Accum);
group_enum_groups_2(K, Accum) ->
    %% record must always exist, as we are iterating over table keys
    [Group] = ets:lookup(group_table, K),
    %% unwrap wrapped buckets
    Buckets = [B#linc_bucket.bucket || B <- Group#linc_group.buckets],
    %% create standard structure
    GroupDesc = #ofp_group_desc_stats{
                   group_id = Group#linc_group.id,
                   type = Group#linc_group.type,
                   buckets = Buckets
                  },
    group_enum_groups_2(ets:next(K), [GroupDesc | Accum]).

%%--------------------------------------------------------------------
%% @internal

select_random_bucket_by_weight(_RandomWeight, _Accum, []) ->
    not_found;
select_random_bucket_by_weight(RandomWeight, Accum, [Bucket|_])
  when RandomWeight >= Accum ->
    Bucket;
select_random_bucket_by_weight(RandomWeight, Accum, [Bucket|Tail]) ->
    select_random_bucket_by_weight(RandomWeight,
                                   Accum + (Bucket#linc_bucket.bucket)#ofp_bucket.weight,
                                   Tail).

-spec calculate_total_weight(Buckets :: [ofp_bucket()]) -> integer().
calculate_total_weight(Buckets) ->
    lists:foldl(fun(B, Sum) ->
                        case B#ofp_bucket.weight of
                            W when is_integer(W) -> W;
                            _ -> 1
                        end + Sum
                end, 0, Buckets).
