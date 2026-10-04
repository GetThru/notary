defmodule Outlaw.Conformance.LiveView.DomTest do
  use ExUnit.Case, async: true

  alias Outlaw.Conformance.LiveView.Dom
  import Outlaw.Value, only: [model: 1, set: 1]

  defp var(name, attr, value),
    do: ~s(<span hidden data-outlaw-var="#{name}" #{attr}='#{value}'></span>)

  test "json: strings, integers, booleans, arrays as sequences, objects as records" do
    html =
      "<div>" <>
        var("s", "data-outlaw-json", ~s("payment")) <>
        var("i", "data-outlaw-json", "3") <>
        var("b", "data-outlaw-json", "true") <>
        var("q", "data-outlaw-json", ~s([1, "a"])) <>
        var("r", "data-outlaw-json", ~s({"k": 1})) <> "</div>"

    assert Dom.decode(html) ==
             {:ok,
              %{"s" => "payment", "i" => 3, "b" => true, "q" => [1, "a"], "r" => %{"k" => 1}}}
  end

  test "json: an empty object is the empty function <<>>, at any depth" do
    assert Dom.decode(var("e", "data-outlaw-json", "{}")) == {:ok, %{"e" => []}}

    assert Dom.decode(var("n", "data-outlaw-json", ~s({"a": {}}))) ==
             {:ok, %{"n" => %{"a" => []}}}

    assert Dom.decode(var("l", "data-outlaw-json", "[{}]")) == {:ok, %{"l" => [[]]}}
  end

  test "tla: sets and model values via Outlaw.Value" do
    html = var("users", "data-outlaw-value", "{u1, u2}") <> var("me", "data-outlaw-value", "u1")

    assert Dom.decode(html) ==
             {:ok, %{"users" => set([model("u1"), model("u2")]), "me" => model("u1")}}
  end

  test "no markers is an empty projection" do
    assert Dom.decode("<div>nothing</div>") == {:ok, %{}}
  end

  test "works on a full document (a static page after a redirect)" do
    html =
      "<!DOCTYPE html><html><body>" <>
        var("page", "data-outlaw-json", ~s("plain")) <> "</body></html>"

    assert Dom.decode(html) == {:ok, %{"page" => "plain"}}
  end

  test "the same variable twice with the same value is fine" do
    html = var("s", "data-outlaw-json", ~s("a")) <> var("s", "data-outlaw-value", ~s("a"))
    assert Dom.decode(html) == {:ok, %{"s" => "a"}}
  end

  test "the same variable twice with different values names both" do
    html = var("s", "data-outlaw-json", ~s("a")) <> var("s", "data-outlaw-json", ~s("b"))
    assert {:error, %{variable: "s", message: message}} = Dom.decode(html)
    assert message =~ ~s("a")
    assert message =~ ~s("b")
  end

  test "both value attributes, or neither, is an error" do
    both = ~s(<span data-outlaw-var="s" data-outlaw-json='1' data-outlaw-value='1'></span>)
    neither = ~s(<span data-outlaw-var="s"></span>)
    assert {:error, %{variable: "s", message: m1}} = Dom.decode(both)
    assert m1 =~ "exactly one"
    assert {:error, %{variable: "s", message: m2}} = Dom.decode(neither)
    assert m2 =~ "exactly one"
  end

  test "json null, floats, and nested null/floats are errors" do
    for raw <- ["null", "1.5", "[1, null]", ~s({"k": 2.0})] do
      assert {:error, %{variable: "v", message: message}} =
               Dom.decode(var("v", "data-outlaw-json", raw))

      assert message =~ raw
    end
  end

  test "unparseable json or tla quotes the raw text" do
    assert {:error, %{variable: "v", message: m1}} =
             Dom.decode(var("v", "data-outlaw-json", "{nope"))

    assert m1 =~ "{nope"

    assert {:error, %{variable: "v", message: m2}} =
             Dom.decode(var("v", "data-outlaw-value", "<<<"))

    assert m2 =~ "<<<"
  end
end
