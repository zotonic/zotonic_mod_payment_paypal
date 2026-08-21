-module(m_payment_paypal_api_tests).
-moduledoc("
EUnit tests for PayPal API value formatting.
").

-include_lib("eunit/include/eunit.hrl").

amount_string_test() ->
    ?assertEqual(<<"12.34">>, m_payment_paypal_api:amount_string(12.34, <<"EUR">>)),
    ?assertEqual(<<"1234">>, m_payment_paypal_api:amount_string(1234, <<"HUF">>)),
    ?assertEqual(<<"1234">>, m_payment_paypal_api:amount_string(1234, <<"JPY">>)),
    ?assertEqual(<<"1234">>, m_payment_paypal_api:amount_string(1234, <<"TWD">>)).
