defmodule Ravanshenasi.Frameworks.ThinkingFrameworkTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Frameworks.ThinkingFramework

  test "changeset válido com name + description" do
    cs = ThinkingFramework.changeset(%ThinkingFramework{}, %{name: "TCC", description: "..."})
    assert cs.valid?
  end

  test "name é obrigatório" do
    cs = ThinkingFramework.changeset(%ThinkingFramework{}, %{description: "x"})
    refute cs.valid?
    assert %{name: ["can't be blank"]} = errors_on(cs)
  end
end
