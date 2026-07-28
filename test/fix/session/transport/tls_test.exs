defmodule FIX.Session.Transport.TLSTest do
  use ExUnit.Case, async: true

  alias FIX.Session.Transport.TLS

  @localhost ~c"localhost"

  setup_all do
    %{server_config: server_config, client_config: client_config} =
      FIX.Session.TLSCerts.generate()

    %{server_config: server_config, cacerts: client_config[:cacerts]}
  end

  describe "build_options/2" do
    test "applies secure defaults" do
      options = TLS.build_options(@localhost, [])

      assert options[:nodelay] == true
      assert options[:keepalive] == true
      assert options[:verify] == :verify_peer
      assert [match_fun: match_fun] = options[:customize_hostname_check]
      assert is_function(match_fun)
      assert options[:server_name_indication] == @localhost
      assert [_ | _] = options[:cacerts]
    end

    test "user options override defaults" do
      options = TLS.build_options(@localhost, verify: :verify_none)

      assert options[:verify] == :verify_none
      assert Enum.count(options, &match?({:verify, _}, &1)) == 1
    end

    test "forced options cannot be overridden" do
      options = TLS.build_options(@localhost, active: true, packet: :line, mode: :list)

      assert options[:active] == false
      assert options[:packet] == :raw
      assert options[:mode] == :binary
      assert Enum.count(options, &match?({:active, _}, &1)) == 1
      assert Enum.count(options, &match?({:packet, _}, &1)) == 1
      assert Enum.count(options, &match?({:mode, _}, &1)) == 1
    end

    test "user cacerts suppresses the trust-store default" do
      options = TLS.build_options(@localhost, cacerts: [<<1>>])

      assert options[:cacerts] == [<<1>>]
      assert Enum.count(options, &match?({:cacerts, _}, &1)) == 1
    end

    test "user cacertfile suppresses the trust-store default" do
      options = TLS.build_options(@localhost, cacertfile: "ca.pem")

      refute Keyword.has_key?(options, :cacerts)
      assert options[:cacertfile] == "ca.pem"
    end

    test "IP-literal hosts disable SNI" do
      options = TLS.build_options(~c"127.0.0.1", [])

      assert options[:server_name_indication] == :disable
    end

    test "IP-tuple hosts omit SNI" do
      options = TLS.build_options({127, 0, 0, 1}, [])

      refute Keyword.has_key?(options, :server_name_indication)
    end

    test "tolerates bare-atom options" do
      options = TLS.build_options(@localhost, [:binary, {:verify, :verify_none}])

      assert :binary in options
      assert options[:verify] == :verify_none
    end
  end

  describe "against a real ssl listener" do
    setup %{server_config: server_config} do
      {:ok, listener} =
        :ssl.listen(0, [mode: :binary, packet: :raw, active: false] ++ server_config)

      {:ok, {_address, port}} = :ssl.sockname(listener)

      test_pid = self()

      server =
        Task.async(fn ->
          with {:ok, transport_socket} <- :ssl.transport_accept(listener, 5_000),
               {:ok, socket} <- :ssl.handshake(transport_socket, 5_000),
               :ok <- :ssl.controlling_process(socket, test_pid) do
            {:ok, socket}
          end
        end)

      on_exit(fn -> :ssl.close(listener) end)

      %{port: port, server: server}
    end

    test "connects, sends, and receives with the default verify_peer", ctx do
      assert {:ok, socket} = TLS.connect("localhost", ctx.port, [cacerts: ctx.cacerts], 5_000)
      assert {:ok, server_socket} = Task.await(ctx.server)

      assert :ok = TLS.send(socket, "8=FIX.4.4\x019=5\x0135=0\x01")
      assert {:ok, "8=FIX.4.4\x019=5\x0135=0\x01"} = :ssl.recv(server_socket, 0, 5_000)

      :ok = :ssl.send(server_socket, "8=FIX.4.4\x019=5\x0135=1\x01")
      refute_receive {:ssl, _socket, _bytes}, 100
      assert :ok = TLS.set_active_once(socket)
      assert_receive {:ssl, ^socket, "8=FIX.4.4\x019=5\x0135=1\x01"}, 5_000

      assert :ok = TLS.set_active_once(socket)
      :ok = :ssl.close(server_socket)
      assert_receive {:ssl_closed, ^socket}, 5_000

      assert :ok = TLS.close(socket)
    end

    @tag capture_log: true
    test "rejects a certificate from an unknown CA by default", ctx do
      assert {:error, {:tls_alert, {:unknown_ca, _description}}} =
               TLS.connect("localhost", ctx.port, [], 5_000)

      Task.shutdown(ctx.server, :brutal_kill)
    end

    @tag capture_log: true
    test "verify: :verify_none connects without the CA", ctx do
      assert {:ok, socket} =
               TLS.connect(
                 "localhost",
                 ctx.port,
                 [verify: :verify_none, log_level: :error],
                 5_000
               )

      assert {:ok, _server_socket} = Task.await(ctx.server)
      assert :ok = TLS.close(socket)
    end
  end
end
