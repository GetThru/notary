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

          def project(ctx) do
            %{"step" => ctx |> text("#step-title") |> String.downcase(),
              "address" => has?(ctx, "#address-summary")}
          end

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

      ensure_test_supervisor()
      conn = Phoenix.ConnTest.build_conn()
      ctx = %Ctx{conn: conn, endpoint: endpoint}

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

    @doc """
    Cleans up what `mount/2` registered for the calling process. Call it from
    `teardown/1`. Idempotent: it does nothing when this process wasn't
    registered by Outlaw (an ExUnit test process) or was already cleaned up.
    """
    @spec unmount(Ctx.t()) :: :ok
    def unmount(%Ctx{}), do: unregister()

    # Registration is tracked per process, not in ctx: a re-mount in the same
    # process finds the registration already there, and the ctx it returns
    # must still clean it up.
    @registered {__MODULE__, :registered}

    defp unregister do
      with true <- Process.get(@registered, false),
           {:ok, sup} <- ExUnit.OnExitHandler.get_supervisor(self()) do
        Process.delete(@registered)
        stop_test_supervisor(sup)
      else
        _ -> :ok
      end
    end

    # `ExUnit.OnExitHandler.run/2` waits for the registered process's test
    # supervisor to go down, which normally happens because that process
    # itself has already exited (its death takes the linked supervisor with
    # it) before some *other* process calls `run/2` on its behalf. Here the
    # registered process is us, and we're still running, so nothing kills the
    # supervisor on its own and `run/2` would block for the full timeout.
    # Stop it ourselves first, trapping exits so the cascade (supervisor ->
    # LiveView channel -> our own linked ClientProxy) doesn't crash this
    # process. `sup` is nil when nothing ever asked for it.
    defp stop_test_supervisor(sup) do
      trapping? = Process.flag(:trap_exit, true)

      try do
        if is_pid(sup), do: Process.exit(sup, :shutdown)
        _ = ExUnit.OnExitHandler.run(self(), 5_000)
        flush_exits()
      after
        Process.flag(:trap_exit, trapping?)
      end

      :ok
    end

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
    # the calling process the way ExUnit's own runner does, and remember (in
    # the process dictionary) that we did, so `unmount/1` knows to clean up.
    defp ensure_test_supervisor do
      {:ok, _} = Application.ensure_all_started(:ex_unit)

      case ExUnit.fetch_test_supervisor() do
        {:ok, _} ->
          :ok

        :error ->
          :ok = ExUnit.OnExitHandler.register(self())
          Process.put(@registered, true)
          :ok
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

        %Plug.Conn{status: status} ->
          unregister()

          raise Outlaw.Error.new(
                  :invalid_mapping,
                  "GET #{inspect(path)} answered with status #{status}; Outlaw.Conformance.LiveView needs a page (200) or a redirect (3xx)",
                  %{path: path, status: status}
                )
      end
    end

    defp live_result({:ok, view, html}, conn), do: {:live, conn, view, html}
    defp live_result({:error, {_kind, %{to: _} = opts}}, conn), do: {:redirect, conn, opts}

    @max_redirects 5

    defp put_result(ctx, result, hops \\ @max_redirects)

    defp put_result(ctx, {:live, conn, view, html}, _hops) do
      Phoenix.LiveViewTest.render_async(view, Outlaw.Config.get(:settle_timeout))
      %{ctx | conn: conn, view: view, html: html}
    end

    defp put_result(ctx, {:static, conn, html}, _hops),
      do: %{ctx | conn: conn, view: nil, html: html}

    defp put_result(ctx, {:redirect, conn, opts}, hops) when hops > 0 do
      {conn, to} = Phoenix.LiveViewTest.__follow_redirect__(conn, ctx.endpoint, nil, opts)
      put_result(ctx, visit(conn, ctx.endpoint, to), hops - 1)
    end

    defp put_result(_ctx, {:redirect, _conn, opts}, 0),
      do:
        raise(
          Outlaw.Error.new(
            :invalid_mapping,
            "more than #{@max_redirects} redirects in a row (last to #{opts.to})"
          )
        )

    @submit_buttons "button:not([type]), button[type=submit], input[type=submit]"

    @doc """
    Clicks the element matching `selector`. Returns
    `{:rejected, {:not_available, selector}, ctx}` without sending an event
    when the element is missing or `disabled` (design spec §8.3/§8.4).
    """
    @spec click(Ctx.t(), String.t()) ::
            {:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}
    def click(%Ctx{} = ctx, selector) do
      with {:ok, _node} <- available(ctx, selector, :click) do
        act(ctx, fn view ->
          view |> Phoenix.LiveViewTest.element(selector) |> Phoenix.LiveViewTest.render_click()
        end)
      end
    end

    @doc "Submits the form matching `selector` with `values`. Unavailable if missing, disabled, or every submit button is disabled."
    @spec submit(Ctx.t(), String.t(), map()) ::
            {:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}
    def submit(%Ctx{} = ctx, selector, values) do
      with {:ok, _node} <- available(ctx, selector, :submit) do
        act(ctx, fn view ->
          view
          |> Phoenix.LiveViewTest.form(selector, values)
          |> Phoenix.LiveViewTest.render_submit()
        end)
      end
    end

    @doc "Sends a change event for the form matching `selector`. Unavailable if missing or disabled."
    @spec change(Ctx.t(), String.t(), map()) ::
            {:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}
    def change(%Ctx{} = ctx, selector, values) do
      with {:ok, _node} <- available(ctx, selector, :change) do
        act(ctx, fn view ->
          view
          |> Phoenix.LiveViewTest.form(selector, values)
          |> Phoenix.LiveViewTest.render_change()
        end)
      end
    end

    @doc """
    The trimmed text content of the element matching `selector`, with
    internal whitespace runs (spaces, tabs, newlines) collapsed to one space.
    Needs exactly one match; 0 or 2+ throws `:invalid_projection` for the
    runner, naming the helper, selector, and match count.
    """
    @spec text(Ctx.t(), String.t()) :: String.t()
    def text(%Ctx{} = ctx, selector) do
      nodes = exactly_one!(ctx, selector, "text(ctx, #{inspect(selector)})")
      nodes |> LazyHTML.text() |> normalize_text()
    end

    @doc """
    The trimmed, whitespace-collapsed text content (same normalisation as
    `text/2`) of every element matching `selector`, in document order. `[]`
    when nothing matches.
    """
    @spec texts(Ctx.t(), String.t()) :: [String.t()]
    def texts(%Ctx{} = ctx, selector) do
      ctx |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> normalize_text()))
    end

    @doc "Whether any element matches `selector`."
    @spec has?(Ctx.t(), String.t()) :: boolean()
    def has?(%Ctx{} = ctx, selector), do: ctx |> query(selector) |> Enum.any?()

    @doc "The number of elements matching `selector`."
    @spec count(Ctx.t(), String.t()) :: non_neg_integer()
    def count(%Ctx{} = ctx, selector), do: ctx |> query(selector) |> Enum.count()

    @doc """
    The value of attribute `name` on the element matching `selector`, or
    `nil` if the attribute is absent. A boolean attribute present with no
    value (e.g. `disabled`) gives `""`. Needs exactly one match; 0 or 2+
    throws `:invalid_projection` for the runner.
    """
    @spec attr(Ctx.t(), String.t(), String.t()) :: String.t() | nil
    def attr(%Ctx{} = ctx, selector, name) do
      nodes = exactly_one!(ctx, selector, "attr(ctx, #{inspect(selector)}, #{inspect(name)})")
      attribute_or(nodes, name, nil)
    end

    @doc """
    The current value of the element matching `selector`: an `<input>`'s
    `value` attribute (`""` if absent — this includes checkboxes and radios,
    whose `value` attribute is returned regardless of whether they're
    checked), a `<textarea>`'s raw text content (not whitespace-collapsed),
    or a `<select>`'s `selected` option's `value` attribute, falling back to
    the first option's when none is marked `selected` (`""` when there are no
    options at all). Needs exactly one match; 0 or 2+ throws
    `:invalid_projection` for the runner.
    """
    @spec value(Ctx.t(), String.t()) :: String.t()
    def value(%Ctx{} = ctx, selector) do
      nodes = exactly_one!(ctx, selector, "value(ctx, #{inspect(selector)})")

      case LazyHTML.tag(nodes) do
        ["textarea"] -> LazyHTML.text(nodes)
        ["select"] -> select_value(nodes)
        _ -> attribute_or(nodes, "value", "")
      end
    end

    @doc """
    The current LiveView's socket assigns map. Depends on LiveView internals
    (the channel process's state, read via `:sys.get_state/1`); prefer the
    DOM helpers above, and reach for `assigns/1` only when a fact truly isn't
    shown anywhere in the rendered page. Raises `Outlaw.Error` when the
    current page isn't a LiveView.
    """
    @spec assigns(Ctx.t()) :: map()
    def assigns(%Ctx{view: view}) when not is_nil(view) do
      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      assigns
    end

    def assigns(%Ctx{view: nil}) do
      raise Outlaw.Error.new(
              :invalid_mapping,
              "assigns/1 needs a LiveView; the current page is not one"
            )
    end

    defp select_value(nodes) do
      options = LazyHTML.query(nodes, "option")
      selected = LazyHTML.query(nodes, "option[selected]")

      cond do
        Enum.any?(selected) -> selected |> Enum.at(0) |> attribute_or("value", "")
        Enum.any?(options) -> options |> Enum.at(0) |> attribute_or("value", "")
        true -> ""
      end
    end

    defp attribute_or(nodes, name, default) do
      case LazyHTML.attribute(nodes, name) do
        [value] -> value
        [] -> default
      end
    end

    defp normalize_text(text), do: text |> String.trim() |> String.replace(~r/\s+/, " ")

    defp exactly_one!(ctx, selector, call) do
      nodes = query(ctx, selector)

      case Enum.count(nodes) do
        1 ->
          nodes

        n ->
          throw(
            {:outlaw_fail, :invalid_projection,
             %{message: "#{call} matched #{n} elements; it needs exactly one"}}
          )
      end
    end

    defp query(%Ctx{} = ctx, selector),
      do: ctx |> current_html() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp current_html(%Ctx{view: nil, html: html}), do: html
    defp current_html(%Ctx{view: view}), do: Phoenix.LiveViewTest.render(view)

    defp available(%Ctx{view: nil} = ctx, selector, _kind),
      do: {:rejected, {:not_available, selector}, ctx}

    defp available(%Ctx{} = ctx, selector, kind) do
      nodes = query(ctx, selector)

      case Enum.count(nodes) do
        0 ->
          {:rejected, {:not_available, selector}, ctx}

        1 ->
          if enabled?(nodes, kind),
            do: {:ok, nodes},
            else: {:rejected, {:not_available, selector}, ctx}

        n ->
          raise Outlaw.Error.new(
                  :invalid_mapping,
                  "selector #{inspect(selector)} matches #{n} elements; Outlaw.Conformance.LiveView helpers need exactly one"
                )
      end
    end

    defp enabled?(node, kind) do
      disabled? = LazyHTML.attribute(node, "disabled") != []

      cond do
        disabled? -> false
        kind != :submit -> true
        true -> submit_enabled?(LazyHTML.query(node, @submit_buttons))
      end
    end

    # No submit button at all: still submittable (Enter in a field).
    defp submit_enabled?(buttons) do
      Enum.count(buttons) == 0 or Enum.any?(buttons, &(LazyHTML.attribute(&1, "disabled") == []))
    end

    defp act(%Ctx{view: view} = ctx, fun) do
      case fun.(view) do
        html when is_binary(html) ->
          Phoenix.LiveViewTest.render_async(view, Outlaw.Config.get(:settle_timeout))
          {:ok, ctx}

        {:error, {kind, %{to: _} = opts}} when kind in [:live_redirect, :redirect] ->
          {:ok, put_result(ctx, {:redirect, ctx.conn, opts})}
      end
    end
  end
end
