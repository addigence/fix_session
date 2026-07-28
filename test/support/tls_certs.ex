defmodule FIX.Session.TLSCerts do
  @moduledoc """
  In-memory TLS certificate chains for transport tests, generated with
  `:public_key.pkix_test_data/1`. Nothing touches disk and no external
  tooling is required.
  """

  # subjectAltName (2.5.29.17) so verify_peer accepts connections to
  # "localhost" and 127.0.0.1.
  @san {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", iPAddress: <<127, 0, 0, 1>>]}

  # The pkix_test_data defaults are rejected by TLS 1.3 peers
  # (unable_to_supply_acceptable_cert); sha256 + P-256 is accepted.
  @cert_opts [digest: :sha256, key: {:namedCurve, :secp256r1}]

  @doc """
  Returns `%{server_config: ssl_opts, client_config: ssl_opts}` with a
  fresh root -> peer chain per side.
  """
  def generate do
    :public_key.pkix_test_data(%{
      server_chain: %{
        root: @cert_opts,
        intermediates: [],
        peer: @cert_opts ++ [extensions: [@san]]
      },
      client_chain: %{root: @cert_opts, intermediates: [], peer: @cert_opts}
    })
  end
end
