%% @copyright 2026 Marc Worrell
%% @doc Tests for PayPal amounts, orders and payment status handling.
%% @end

%% Copyright 2026 Marc Worrell
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

-module(m_payment_paypal_api_tests).
-moduledoc("
EUnit tests for PayPal API value formatting, payment status mapping, and webhook verification.
").

-include_lib("eunit/include/eunit.hrl").

amount_string_test() ->
    ?assertEqual(<<"12.34">>, m_payment_paypal_api:amount_string(12.34, <<"EUR">>)),
    ?assertEqual(<<"1234">>, m_payment_paypal_api:amount_string(1234, <<"HUF">>)),
    ?assertEqual(<<"1234">>, m_payment_paypal_api:amount_string(1234, <<"JPY">>)),
    ?assertEqual(<<"1234">>, m_payment_paypal_api:amount_string(1234, <<"TWD">>)).

webhook_verification_payload_preserves_raw_body_test() ->
    Body = <<"{\"create_time\":\"2026-08-21T06:30:33.674Z\",\n"
             " \"resource\":{\"url\":\"https://api.paypal.com/order/123\"}}">>,
    Headers = #{
        <<"auth_algo">> => <<"SHA256withRSA">>,
        <<"cert_url">> => <<"https://api.paypal.com/cert/123">>,
        <<"transmission_id">> => <<"transmission-id">>,
        <<"transmission_sig">> => <<"signature/+==">>,
        <<"transmission_time">> => <<"2026-08-21T06:30:33Z">>
    },
    Payload = m_payment_paypal_api:webhook_verification_payload(
        Body,
        <<"webhook-id">>,
        Headers),
    EventSuffix = iolist_to_binary([<<"\"webhook_event\":">>, Body, <<"}">>]),
    ?assertEqual(
        {byte_size(Payload) - byte_size(EventSuffix), byte_size(EventSuffix)},
        binary:match(Payload, EventSuffix)),
    ?assertMatch(#{ <<"webhook_event">> := #{} }, z_json:decode(Payload)).

order_payment_status_test() ->
    ?assertEqual({ok, new}, order_status(<<"CREATED">>)),
    ?assertEqual({ok, new}, order_status(<<"SAVED">>)),
    ?assertEqual({ok, new}, order_status(<<"PAYER_ACTION_REQUIRED">>)),
    ?assertEqual({ok, pending}, order_status(<<"APPROVED">>)),
    ?assertEqual({ok, cancelled}, order_status(<<"VOIDED">>)),
    ?assertEqual(
        {error, {order_status, <<"UNKNOWN">>}},
        order_status(<<"UNKNOWN">>)).

completed_order_capture_status_test() ->
    ?assertEqual({ok, paid}, completed_order_status(<<"COMPLETED">>)),
    ?assertEqual({ok, pending}, completed_order_status(<<"PENDING">>)),
    ?assertEqual({ok, failed}, completed_order_status(<<"DECLINED">>)),
    ?assertEqual({ok, failed}, completed_order_status(<<"DENIED">>)),
    ?assertEqual({ok, failed}, completed_order_status(<<"FAILED">>)),
    ?assertEqual({ok, refunded}, completed_order_status(<<"REFUNDED">>)),
    ?assertEqual({ok, paid}, completed_order_status(<<"PARTIALLY_REFUNDED">>)),
    ?assertEqual(
        {error, {capture_status, [ <<"UNKNOWN">> ]}},
        completed_order_status(<<"UNKNOWN">>)),
    ?assertEqual(
        {error, {capture_status, undefined}},
        m_payment_paypal_api:order_payment_status(#{ <<"status">> => <<"COMPLETED">> })).

order_status(Status) ->
    m_payment_paypal_api:order_payment_status(#{ <<"status">> => Status }).

completed_order_status(CaptureStatus) ->
    m_payment_paypal_api:order_payment_status(#{
        <<"status">> => <<"COMPLETED">>,
        <<"purchase_units">> => [
            #{
                <<"payments">> => #{
                    <<"captures">> => [
                        #{ <<"status">> => CaptureStatus }
                    ]
                }
            }
        ]
    }).

external_order_test() ->
    Unit = #{<<"amount">> => #{<<"currency_code">> => <<"EUR">>, <<"value">> => <<"12.34">>},
             <<"payments">> => #{<<"captures">> => [#{<<"status">> => <<"COMPLETED">>}]}},
    Order = #{<<"id">> => <<"ORDER1">>, <<"status">> => <<"COMPLETED">>,
              <<"purchase_units">> => [Unit], <<"update_time">> => <<"2026-10-29T10:00:00Z">>},
    {ok, D} = m_payment_paypal_api:webhook_payment(Order),
    ?assertEqual(undefined, maps:get(payment_nr, D)),
    ?assertEqual(<<"ORDER1">>, maps:get(psp_external_id, D)),
    ?assertEqual(paid, maps:get(status, D)),
    ?assertEqual(12.34, maps:get(amount, D)),
    {ok, Multi} = m_payment_paypal_api:webhook_payment(Order#{<<"purchase_units">> => [Unit, Unit]}),
    ?assertEqual(24.68, maps:get(amount, Multi)),
    ?assertEqual({error, amount}, m_payment_paypal_api:webhook_payment(Order#{<<"purchase_units">> =>
        [Unit, Unit#{<<"amount">> => #{<<"currency_code">> => <<"USD">>, <<"value">> => <<"1">>}}]})).

external_capture_and_refund_test() ->
    Capture = #{<<"id">> => <<"CAPTURE1">>, <<"status">> => <<"PARTIALLY_REFUNDED">>,
        <<"amount">> => #{<<"currency_code">> => <<"USD">>, <<"value">> => <<"100.00">>}},
    {ok, D} = m_payment_paypal_api:webhook_payment(Capture),
    ?assertEqual(<<"capture:CAPTURE1">>, maps:get(psp_external_id, D)),
    ?assertEqual(100.0, maps:get(amount, D)),
    ?assertEqual(paid, maps:get(status, D)),
    Refund = #{<<"id">> => <<"REFUND1">>, <<"links">> => [#{<<"rel">> => <<"up">>,
        <<"href">> => <<"https://api-m.paypal.com/v2/payments/captures/CAPTURE1">>}]},
    ?assertEqual(<<"CAPTURE1">>, m_payment_paypal_api:refund_capture_id(Refund)),
    ?assertEqual(undefined, m_payment_paypal_api:refund_capture_id(#{<<"links">> => [#{
        <<"rel">> => <<"up">>, <<"href">> => <<"https://api-m.paypal.com/v2/payments/captures/../../other">>}]})).
