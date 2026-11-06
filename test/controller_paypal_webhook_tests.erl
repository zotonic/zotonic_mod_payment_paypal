%% Copyright 2026 Marc Worrell. SPDX-License-Identifier: Apache-2.0
%% @doc Verified webhook events survive the authorization-to-processing handoff.
-module(controller_paypal_webhook_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

verified_event_test() ->
    Body = <<"{\"id\":\"WH-test\",\"event_type\":\"PAYMENT.CAPTURE.COMPLETED\"}">>,
    Event = z_json:decode(Body),
    Modules = [cowmachine_req, m_payment_paypal_api],
    meck:new(Modules, [passthrough, no_link]),
    try
        meck:expect(cowmachine_req, req_body, fun(C) -> {Body, C} end),
        meck:expect(m_payment_paypal_api, is_valid_webhook_signature, fun(B, _) ->
            ?assertEqual(Body, B),
            true
        end),
        meck:expect(m_payment_paypal_api, webhook_event, fun(E, _) ->
            ?assertEqual(Event, E),
            ok
        end),
        {true, Context} = controller_paypal_webhook:is_authorized(#context{}),
        ?assertEqual(Body, z_context:get(body, Context)),
        ?assertEqual(Event, z_context:get(paypal_event, Context)),
        ?assertEqual({true, Context},
            controller_paypal_webhook:process(<<"POST">>, undefined, undefined, Context)),
        ?assertEqual(1, meck:num_calls(m_payment_paypal_api, webhook_event, '_'))
    after
        meck:unload(Modules)
    end.
