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
%% @doc Userspace implementation of the OpenFlow Switch logic.
-module(linc_us4_oe).

-behaviour(gen_switch).

%% gen_switch callbacks
-export([start/1,
         stop/1,
         handle_message/2]).

%% Backend API
-export([is_port_valid/2,
         is_queue_valid/3,
         set_datapath_mac/2,
         log_message_sent/1,
         set_monitor_data/3]).

%% Handle all message types
-export([ofp_features_request/2,
         ofp_flow_mod/2,
         ofp_table_mod/2,
         ofp_port_mod/2,
         ofp_group_mod/2,
         ofp_packet_out/2,
         ofp_echo_request/2,
         ofp_get_config_request/2,
         ofp_set_config/2,
         ofp_barrier_request/2,
         ofp_queue_get_config_request/2,
         ofp_desc_request/2,
         ofp_flow_stats_request/2,
         ofp_aggregate_stats_request/2,
         ofp_table_stats_request/2,
         ofp_table_features_request/2,
         ofp_port_desc_request/2,
         ofp_port_stats_request/2,
         ofp_queue_stats_request/2,
         ofp_group_stats_request/2,
         ofp_group_desc_request/2,
         ofp_group_features_request/2,
         ofp_meter_mod/2,
         ofp_meter_stats_request/2,
         ofp_meter_config_request/2,
         ofp_meter_features_request/2,
         ofp_experimenter_request/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4_oe.hrl").

-record(state, {
          flow_state,
          buffer_state,
          switch_id :: integer(),
          datapath_mac :: binary(),
          datapath_id :: binary(),
          switch_config = [{flags, []}, {miss_send_len, no_buffer}] ::
            [switch_config_opt()]
         }).
-type state() :: #state{}.

-type switch_config_opt() :: {flags, list(ofp_config_flags())} |
                              {miss_send_len, ofp_packet_in_bytes()}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, Version :: 4, state()}.
start(BackendOpts) ->
    try
        {switch_id, SwitchId} = lists:keyfind(switch_id, 1, BackendOpts),
        {datapath_mac, DatapathMac} = lists:keyfind(datapath_mac, 1, BackendOpts),
        {datapath_id, DatapathId} = lists:keyfind(datapath_id, 1, BackendOpts),
        {config, Config} = lists:keyfind(config, 1, BackendOpts),
        BufferState = linc_buffer:initialize(SwitchId),
        {ok, _Pid} = linc_us4_oe_sup:start_backend_sup(SwitchId),
        linc_us4_oe_groups:initialize(SwitchId),
        FlowState = linc_us4_oe_flow:initialize(SwitchId),
        linc_us4_oe_port:initialize(SwitchId, Config),
        {ok, 4, #state{flow_state = FlowState,
                       buffer_state = BufferState,
                       switch_id = SwitchId,
                       datapath_mac = DatapathMac,
                       datapath_id = DatapathId}}
    catch
        _:Error ->
            {error, Error}
    end.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(#state{flow_state = FlowState,
            buffer_state = BufferState,
            switch_id = SwitchId}) ->
    linc_us4_oe_port:terminate(SwitchId),
    linc_us4_oe_flow:terminate(FlowState),
    linc_us4_oe_groups:terminate(SwitchId),
    linc_buffer:terminate(BufferState),
    ok;
stop([]) ->
    ok.

-spec handle_message(ofp_message_body(), state()) ->
                            {noreply, state()} |
                            {reply, ofp_message(), state()}.
handle_message(MessageBody, State) ->
    MessageName = element(1, MessageBody),
    erlang:apply(?MODULE, MessageName, [State, MessageBody]).

%%%-----------------------------------------------------------------------------
%%% Backend API
%%%-----------------------------------------------------------------------------

-spec is_port_valid(integer(), ofp_port_no()) -> boolean().
is_port_valid(SwitchId, PortNo) ->
    linc_us4_oe_port:is_valid(SwitchId, PortNo).

-spec is_queue_valid(integer(), ofp_port_no(), ofp_queue_id()) -> boolean().
is_queue_valid(SwitchId, PortNo, QueueId) ->
    linc_us4_oe_queue:is_valid(SwitchId, PortNo, QueueId).

set_datapath_mac(State, NewMac) ->
    State#state{datapath_mac = NewMac}.

-spec log_message_sent(ofp_message()) -> term().
log_message_sent(#ofp_message{body = Body} = Message)
  when is_record(Body, ofp_error_msg) ->
    ?DEBUG("[OF_ERROR] Sent message to controller: ~w~n", [Message]);
log_message_sent(Message) ->
    ?DEBUG("Sent message to controller: ~w~n", [Message]).

-spec set_monitor_data(pid(), integer(), state()) -> state().
set_monitor_data(_ClientPid, _Xid, State) ->
    State.


%%%-----------------------------------------------------------------------------
%%% Handling of messages
%%%-----------------------------------------------------------------------------

ofp_features_request(#state{switch_id = SwitchId,
                            datapath_mac = DatapathMac,
                            datapath_id = undefined} = State,
                     #ofp_features_request{}) ->
    FeaturesReply = #ofp_features_reply{datapath_mac = DatapathMac,
                                        datapath_id = SwitchId,
                                        n_buffers = 0,
                                        n_tables = 255,
                                        auxiliary_id = 0,
                                        capabilities = ?CAPABILITIES},
    {reply, FeaturesReply, State};
ofp_features_request(#state{datapath_id = SysConfigDatapathId} = State,
                     #ofp_features_request{}) ->
    <<SwitchId:16, DataPathMac:48/bits>> = SysConfigDatapathId,
    FeaturesReply = #ofp_features_reply{datapath_id = SwitchId,
                                        datapath_mac = DataPathMac,
                                        n_buffers = 0,
                                        n_tables = 255,
                                        auxiliary_id = 0,
                                        capabilities = ?CAPABILITIES},
    {reply, FeaturesReply, State}.

%% @doc Modify flow entry in the flow table.
-spec ofp_flow_mod(state(), ofp_flow_mod()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_flow_mod(#state{switch_id = SwitchId} = State,
             #ofp_flow_mod{} = FlowMod) ->
    case linc_us4_oe_flow:modify(SwitchId, FlowMod) of
        ok ->
            {noreply, State};
        {error, {Type, Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify flow table configuration.
-spec ofp_table_mod(state(), ofp_table_mod()) ->
                           {noreply, #state{}} |
                           {reply, ofp_message(), #state{}}.
ofp_table_mod(State, #ofp_table_mod{} = TableMod) ->
    case linc_us4_oe_flow:table_mod(TableMod) of
        ok ->
            {noreply, State};
        {error, {Type, Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify port configuration.
-spec ofp_port_mod(state(), ofp_port_mod()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_port_mod(#state{switch_id = SwitchId} = State,
             #ofp_port_mod{} = PortMod) ->
    case linc_us4_oe_port:modify(SwitchId, PortMod) of
        ok ->
            {noreply, State};
        {error, {Type, Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify group entry in the group table.
-spec ofp_group_mod(state(), ofp_group_mod()) ->
                           {noreply, #state{}} |
                           {reply, ofp_message(), #state{}}.
ofp_group_mod(#state{switch_id = SwitchId} = State,
              #ofp_group_mod{} = GroupMod) ->
    case linc_us4_oe_groups:modify(SwitchId, GroupMod) of
        ok ->
            {noreply, State};
        {error, ErrorMsg} ->
            {reply, ErrorMsg, State}
    end.

%% @doc Handle a packet received from controller.
-spec ofp_packet_out(state(), ofp_packet_out()) ->
                            {noreply, #state{}} |
                            {reply, ofp_message(), #state{}}.
ofp_packet_out(#state{switch_id = SwitchId} = State,
               #ofp_packet_out{buffer_id = no_buffer,
                               actions = Actions,
                               in_port = InPort,
                               data = Data}) ->
    Pkt = linc_us4_oe_packet:binary_to_record(Data, SwitchId, InPort),
    linc_us4_oe_actions:apply_list(Pkt, Actions),
    {noreply, State};
ofp_packet_out(#state{switch_id = SwitchId} = State,
               #ofp_packet_out{buffer_id = BufferId,
                               in_port = InPort,
                               actions = Actions}) ->
    case linc_buffer:get_buffer(SwitchId, BufferId) of
        not_found ->
            %% Buffer has been dropped, ignore
            ok;
        Pkt ->
            LincPkt = #linc_pkt{in_port = InPort, packet = Pkt},
            linc_us4_oe_actions:apply_list(
              LincPkt#linc_pkt{packet_in_reason = packet_out}, Actions)
    end,
    {noreply, State}.

%% @doc Reply to echo request.
-spec ofp_echo_request(state(), ofp_echo_request()) ->
                              {reply, ofp_echo_reply(), #state{}}.
ofp_echo_request(State, #ofp_echo_request{data = Data}) ->
    EchoReply = #ofp_echo_reply{data = Data},
    {reply, EchoReply, State}.

%% @doc Reply to get config request.
-spec ofp_get_config_request(state(), ofp_get_config_request()) ->
                                    {reply, ofp_get_config_reply(), #state{}}.
ofp_get_config_request(#state{switch_config = SwitchConfig} = State,
                       #ofp_get_config_request{}) ->
    ConfigReply = #ofp_get_config_reply{flags = proplists:get_value(
                                                  flags,
                                                  SwitchConfig),
                                        miss_send_len = proplists:get_value(
                                                          miss_send_len,
                                                          SwitchConfig)},
    {reply, ConfigReply, State}.

%% @doc Set switch configuration.
-spec ofp_set_config(state(), ofp_set_config()) -> {noreply, state()}.
ofp_set_config(State, #ofp_set_config{flags = Flags,
                                      miss_send_len = MissSendLength}) ->
    SwitchConfig = [{flags, Flags}, {miss_send_len, MissSendLength}],
    {noreply, State#state{switch_config = SwitchConfig}}.

%% @doc Reply to barrier request.
-spec ofp_barrier_request(state(), ofp_barrier_request()) ->
                                 {reply, ofp_barrier_reply(), #state{}}.
ofp_barrier_request(State, #ofp_barrier_request{}) ->
    BarrierReply = #ofp_barrier_reply{},
    {reply, BarrierReply, State}.

%% @doc Reply to get queue config request.
-spec ofp_queue_get_config_request(state(), ofp_queue_get_config_request()) ->
                                          {reply, ofp_get_config_reply(),
                                           #state{}}.
ofp_queue_get_config_request(State,
                             #ofp_queue_get_config_request{port = Port}) ->
    QueueConfigReply = #ofp_queue_get_config_reply{port = Port,
                                                   queues = []},
    {reply, QueueConfigReply, State}.

%% @doc Get switch description statistics.
-spec ofp_desc_request(state(), ofp_desc_request()) ->
                              {reply, ofp_desc_reply(), #state{}}.
ofp_desc_request(State, #ofp_desc_request{}) ->
    {reply, #ofp_desc_reply{flags = [],
                            mfr_desc = get_env(manufacturer_desc),
                            hw_desc = get_env(hardware_desc),
                            sw_desc = get_env(software_desc),
                            serial_num = get_env(serial_number),
                            dp_desc = get_env(datapath_desc)
                           }, State}.

%% @doc Get flow entry statistics.
-spec ofp_flow_stats_request(state(), ofp_flow_stats_request()) ->
                                    {reply, ofp_flow_stats_reply(), #state{}}.
ofp_flow_stats_request(#state{switch_id = SwitchId} = State,
                       #ofp_flow_stats_request{} = Request) ->
    Reply = linc_us4_oe_flow:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
                                         {reply, ofp_aggregate_stats_reply(),
                                          #state{}}.
ofp_aggregate_stats_request(#state{switch_id = SwitchId} = State,
                            #ofp_aggregate_stats_request{} = Request) ->
    Reply = linc_us4_oe_flow:get_aggregate_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
                                     {reply, ofp_table_stats_reply(), #state{}}.
ofp_table_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_table_stats_request{} = Request) ->
    Reply = linc_us4_oe_flow:get_table_stats(SwitchId, Request),
    {reply, Reply, State}.

-spec ofp_table_features_request(state(), #ofp_table_features_request{}) ->
                                        {reply, #ofp_table_features_reply{},
                                         #state{}}.
ofp_table_features_request(#state{switch_id = SwitchId} = State,
                           #ofp_table_features_request{} = Request) ->
    Reply = linc_us4_oe_table_features:handle_req(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get port description.
-spec ofp_port_desc_request(state(), ofp_port_desc_request()) ->
                                   {reply, ofp_port_desc_reply(), #state{}}.
ofp_port_desc_request(#state{switch_id = SwitchId} = State,
                      #ofp_port_desc_request{}) ->
    Reply = linc_us4_oe_port:get_desc(SwitchId),
    {reply, Reply, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
                                    {reply, ofp_port_stats_reply(), #state{}}.
ofp_port_stats_request(#state{switch_id = SwitchId} = State,
                       #ofp_port_stats_request{} = Request) ->
    Reply = linc_us4_oe_port:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
                                     {reply, ofp_queue_stats_reply(), #state{}}.
ofp_queue_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_queue_stats_request{} = Request) ->
    Reply = linc_us4_oe_queue:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
                                     {reply, ofp_group_stats_reply(), #state{}}.
ofp_group_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_group_stats_request{} = Request) ->
    Reply = linc_us4_oe_groups:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get group description statistics.
-spec ofp_group_desc_request(state(), ofp_group_desc_request()) ->
                                    {reply, ofp_group_desc_reply(), #state{}}.
ofp_group_desc_request(#state{switch_id = SwitchId} = State,
                       #ofp_group_desc_request{} = Request) ->
    Reply = linc_us4_oe_groups:get_desc(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_request(state(),
                                 ofp_group_features_request()) ->
                                        {reply, ofp_group_features_reply(),
                                         #state{}}.
ofp_group_features_request(State,
                           #ofp_group_features_request{} = Request) ->
    Reply = linc_us4_oe_groups:get_features(Request),
    {reply, Reply, State}.

%% Meters ----------------------------------------------------------------------

ofp_meter_mod(#state{switch_id = SwitchId} = State,
              #ofp_meter_mod{} = MeterMod) ->
    case linc_us4_oe_meter:modify(SwitchId, MeterMod) of
        noreply ->
            {noreply, State};
        {reply, Reply} ->
            {reply, Reply, State}
    end.

ofp_meter_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_meter_stats_request{meter_id = Id}) ->
    {reply, linc_us4_oe_meter:get_stats(SwitchId, Id), State}.

ofp_meter_config_request(#state{switch_id = SwitchId} = State,
                         #ofp_meter_config_request{meter_id = Id}) ->
    {reply, linc_us4_oe_meter:get_config(SwitchId, Id), State}.

ofp_meter_features_request(State, #ofp_meter_features_request{}) ->
    {reply, linc_us4_oe_meter:get_features(), State}.

%% Experimenters ----------------------------------------------------------------------

ofp_experimenter_request(#state{switch_id = SwitchId} = State,
                         #ofp_experimenter_request{
                            experimenter = ?INFOBLOX_EXPERIMENTER,
                            exp_type = port_desc}) ->
    Reply = linc_us4_oe_port:get_experimental_desc(SwitchId),
    {reply, Reply, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

get_env(Env) ->
    {ok, Value} = application:get_env(linc, Env),
    Value.
