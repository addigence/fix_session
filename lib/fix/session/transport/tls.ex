defmodule FIX.Session.Transport.TLS do
  @moduledoc """
  TLS initiator transport over `:ssl`.

  Sockets are binary, unpacketized, and passive; the session enables each
  read with `set_active_once/1`. User options may tune the connection but
  cannot override the mode, packeting, or active flag the session depends on.

  ## Defaults

  Each default below applies only when the options do not already set it:

   * `verify: :verify_peer` — the peer certificate is verified.
   * `cacerts: :public_key.cacerts_get()` — the OS trust store; applied
      only when the options set neither `:cacerts` nor `:cacertfile`.
   * `customize_hostname_check` with the `:https` match function, so
      wildcard certificates verify.
   * `server_name_indication` derived from the host: hostnames are sent
      as SNI, IP literals disable it.
   * `nodelay: true, keepalive: true` — the same TCP-level tuning as
      `FIX.Session.Transport.TCP`.

  TLS versions and verification depth use the `:ssl` application defaults
  and can likewise be overridden.

  ## Self-signed counterparty certificates

  Prefer pinning the counterparty CA over disabling verification:

      transport: FIX.Session.Transport.TLS,
      transport_options: [cacertfile: "/etc/fix/counterparty_ca.pem"]

  `verify: :verify_none` also works; `:ssl` logs a warning for it, which
  can be silenced with `log_level: :error`.

  ## Connecting by IP address

  When the host is an IP address but the server certificate names a DNS
  host, pass `server_name_indication: ~c"fix.example.com"` — `:ssl` uses
  the SNI value for hostname verification as well. Without it the
  certificate must carry a matching `iPAddress` subject alternative name.

  `:public_key.cacerts_get/0` raises when no OS trust store is available;
  supply `:cacerts` or `:cacertfile` in that case.
  """

  @behaviour FIX.Session.Transport

  # Unlike inet, ssl does not promise that later list entries override
  # earlier ones for TLS-level options, so the final list is built
  # explicitly: user options replace defaults, forced options replace both.
  @forced [mode: :binary, packet: :raw, active: false]
  @forced_keys Keyword.keys(@forced)

  @impl true
  def connect(host, port, options, timeout) do
    host = normalize_host(host)
    :ssl.connect(host, port, build_options(host, options), timeout)
  end

  @impl true
  def send(socket, bytes), do: :ssl.send(socket, bytes)

  @impl true
  def set_active_once(socket), do: :ssl.setopts(socket, active: :once)

  @impl true
  def close(socket), do: :ssl.close(socket)

  @doc false
  def build_options(host, options) do
    user = Enum.reject(options, &forced?/1)
    defaults = Enum.reject(defaults(host, user), fn {key, _} -> keymember?(user, key) end)
    defaults ++ user ++ @forced
  end

  defp defaults(host, user_options) do
    [
      nodelay: true,
      keepalive: true,
      verify: :verify_peer,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ sni_default(host) ++ cacerts_default(user_options)
  end

  # ssl omits SNI for IP tuples on its own; RFC 6066 forbids IP literals.
  defp sni_default(host) when is_tuple(host), do: []

  defp sni_default(host) do
    case :inet.parse_address(host) do
      {:ok, _ip} -> [server_name_indication: :disable]
      {:error, _reason} -> [server_name_indication: host]
    end
  end

  # ssl ignores :cacertfile when :cacerts is present, so the trust-store
  # default must not shadow a user-supplied :cacertfile.
  defp cacerts_default(options) do
    if keymember?(options, :cacerts) or keymember?(options, :cacertfile),
      do: [],
      else: [cacerts: :public_key.cacerts_get()]
  end

  defp forced?({key, _value}), do: key in @forced_keys
  defp forced?(_option), do: false

  defp keymember?(options, key), do: List.keymember?(options, key, 0)

  defp normalize_host(host) when is_binary(host), do: String.to_charlist(host)
  defp normalize_host(host), do: host
end
