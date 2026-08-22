-module(m_payment_paypal_api_tests).
-moduledoc("
EUnit tests for PayPal API value formatting and webhook verification.
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
