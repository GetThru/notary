if Code.ensure_loaded?(Phoenix.LiveViewTest) and Code.ensure_loaded?(LazyHTML) do
  defmodule Outlaw.Conformance.LiveView do
    @moduledoc """
    Helpers for mapping modules that drive a Phoenix LiveView (design spec §8).

        defmodule MyAppWeb.Specs.Wizard do
          use Outlaw.Conformance, spec: "specs/Wizard.tla"
          import Outlaw.Conformance.LiveView

          def init, do: mount(MyAppWeb.WizardLive, endpoint: MyAppWeb.Endpoint)
          def actions, do: %{"Pay" => StreamData.constant(%{}), ...}
          def action("Pay", _, ctx), do: click(ctx, "#pay")
          def project(ctx), do: project_dom(ctx)
          def teardown(ctx), do: unmount(ctx)
        end

    Built on `Phoenix.LiveViewTest`, including some of its undocumented
    functions (`__live__/3`, `__isolated__/4`, `__follow_redirect__/4`), and
    ExUnit's internal test-supervisor registration: LiveViewTest only runs in
    an ExUnit test process, and conformance runs happen in their own process.
    """

    alias Outlaw.Conformance.LiveView.Ctx

    @doc """
    Mounts `target` and returns `{:ok, ctx}`. `target` is a LiveView module
    (mounted in isolation, no router needed) or a path (requires a router;
    redirects are followed; a page that isn't a LiveView gives `view: nil`).

    Options: `:endpoint` (default `config :outlaw, endpoint:`), `:session`
    (for a module target).
    """
    @spec mount(module() | String.t(), keyword()) :: {:ok, Ctx.t()}
    def mount(target, opts \\ []) do
      endpoint =
        opts[:endpoint] || Outlaw.Config.get(:endpoint) ||
          raise Outlaw.Error.new(
                  :invalid_mapping,
                  "Outlaw.Conformance.LiveView.mount/2 needs an endpoint: pass endpoint: MyAppWeb.Endpoint or set config :outlaw, endpoint: MyAppWeb.Endpoint"
                )

      registered? = ensure_test_supervisor()
      conn = Phoenix.ConnTest.build_conn()
      ctx = %Ctx{conn: conn, endpoint: endpoint, registered?: registered?}

      result =
        if is_binary(target) do
          visit(conn, endpoint, target)
        else
          conn
          |> Phoenix.LiveViewTest.__isolated__(endpoint, target, session: opts[:session] || %{})
          |> live_result(conn)
        end

      {:ok, put_result(ctx, result)}
    end

    @doc "Cleans up what `mount/2` registered. Call it from `teardown/1`."
    @spec unmount(Ctx.t()) :: :ok
    def unmount(%Ctx{registered?: true}) do
      # `ExUnit.OnExitHandler.run/2` waits for the registered process's test
      # supervisor to go down, which normally happens because that process
      # itself has already exited (its death takes the linked supervisor
      # with it) before some *other* process calls `run/2` on its behalf.
      # Here the registered process is us, and we're still running, so
      # nothing kills the supervisor on its own and `run/2` would block for
      # the full timeout. Stop it ourselves first, trapping exits so the
      # cascade (supervisor -> LiveView channel -> our own linked
      # ClientProxy) doesn't crash this process.
      trapping? = Process.flag(:trap_exit, true)

      case ExUnit.OnExitHandler.get_supervisor(self()) do
        {:ok, sup} when is_pid(sup) -> Process.exit(sup, :shutdown)
        _ -> :ok
      end

      _ = ExUnit.OnExitHandler.run(self(), 5_000)
      flush_exits()
      Process.flag(:trap_exit, trapping?)
      :ok
    end

    def unmount(%Ctx{}), do: :ok

    defp flush_exits do
      receive do
        {:EXIT, _pid, _reason} -> flush_exits()
      after
        0 -> :ok
      end
    end

    # LiveViewTest refuses to run outside an ExUnit test process
    # (`ExUnit.fetch_test_supervisor/0`). The runner's per-run process isn't
    # one, and `mix outlaw.verify` doesn't start ExUnit at all, so register
    # the calling process the way ExUnit's own runner does. Returns whether
    # we registered (so `unmount/1` knows to clean up).
    defp ensure_test_supervisor do
      {:ok, _} = Application.ensure_all_started(:ex_unit)

      case ExUnit.fetch_test_supervisor() do
        {:ok, _} ->
          false

        :error ->
          :ok = ExUnit.OnExitHandler.register(self())
          true
      end
    end

    @doc false
    # GETs `path`; a LiveView response is connected, anything else is static.
    def visit(conn, endpoint, path) do
      conn = Phoenix.ConnTest.dispatch(conn, endpoint, :get, path, nil)

      case conn do
        %Plug.Conn{status: 200, assigns: %{live_module: _}} ->
          live_result(Phoenix.LiveViewTest.__live__(conn, path, []), conn)

        %Plug.Conn{status: 200} ->
          {:static, conn, conn.resp_body}

        %Plug.Conn{status: status} when status in 300..399 ->
          [to | _] = Plug.Conn.get_resp_header(conn, "location")
          {:redirect, conn, %{to: to}}
      end
    end

    defp live_result({:ok, view, html}, conn), do: {:live, conn, view, html}
    defp live_result({:error, {_kind, %{to: _} = opts}}, conn), do: {:redirect, conn, opts}

    defp put_result(ctx, {:live, conn, view, html}),
      do: %{ctx | conn: conn, view: view, html: html}

    defp put_result(ctx, {:static, conn, html}), do: %{ctx | conn: conn, view: nil, html: html}
    # Mount-time redirects are followed in Task 4; until then they surface plainly.
    defp put_result(_ctx, {:redirect, _conn, opts}),
      do: raise("mount redirected to #{opts.to}; redirect following arrives in Task 4")
  end
end
