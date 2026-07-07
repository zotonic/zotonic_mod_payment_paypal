%% @copyright 2026 Marc Worrell
%% @doc Handle PayPal return redirects after checkout approval or cancellation.
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

-module(controller_paypal_redirect).

-export([
    allowed_methods/1,
    resource_exists/1,
    previously_existed/1,
    moved_temporarily/1
]).

-include_lib("zotonic_core/include/zotonic.hrl").

allowed_methods(Context) ->
    {[ <<"GET">>, <<"POST">> ], Context}.

resource_exists(Context) ->
    {false, Context}.

previously_existed(Context) ->
    {true, Context}.

moved_temporarily(Context) ->
    % Args: token / status=cancel|ok / payment_nr
    PaymentNr = z_context:get_q(<<"payment_nr">>, Context),
    OrderId = z_context:get_q(<<"token">>, Context),
    case z_context:get_q(<<"status">>, Context) of
        <<"ok">> ->
            case m_payment_paypal_api:capture_order(OrderId, Context) of
                {ok, {CapturedPaymentNr, Status}} ->
                    redirect(disp(Status), CapturedPaymentNr, Context);
                {error, _} ->
                    redirect(payment_psp_cancel, PaymentNr, Context)
            end;
        <<"cancel">> ->
            case m_payment_paypal_api:cancel_order(PaymentNr, Context) of
                {ok, {CancelledPaymentNr, Status}} ->
                    redirect(disp(Status), CancelledPaymentNr, Context);
                {error, _} ->
                    redirect(payment_psp_cancel, PaymentNr, Context)
            end;
        Status ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal redirect with unknown status">>,
                result => error,
                reason => unknown_status,
                status => Status
            }),
            redirect(payment_psp_cancel, PaymentNr, Context)
    end.

disp(cancelled) -> payment_psp_cancel;
disp(failed) -> payment_psp_cancel;
disp(paid) -> payment_psp_done;
disp(pending) -> payment_psp_done;
disp(new) -> payment_psp_done.

redirect(Dispatch, PaymentNr, Context) ->
    Args = [
        {payment_nr, PaymentNr}
    ],
    Location = z_context:abs_url(z_dispatcher:url_for(Dispatch, Args, Context), Context),
    {{true, Location}, Context}.
