# Pattern matching + pipes. Run with: elixir main.exs

defmodule Inventory do
  defstruct items: %{}

  def new, do: %__MODULE__{}

  def add(%__MODULE__{items: items} = inv, name, qty) when qty > 0 do
    %{inv | items: Map.update(items, name, qty, &(&1 + qty))}
  end

  def remove(%__MODULE__{items: items} = inv, name, qty) do
    case Map.get(items, name, 0) do
      0 -> {:error, :not_found}
      have when have < qty -> {:error, :insufficient}
      have -> {:ok, %{inv | items: Map.put(items, name, have - qty)}}
    end
  end

  def total(%__MODULE__{items: items}) do
    items |> Map.values() |> Enum.sum()
  end

  def report(%__MODULE__{items: items}) do
    items
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.each(fn {name, qty} -> IO.puts("  #{String.pad_trailing(name, 10)} #{qty}") end)
  end
end

inv =
  Inventory.new()
  |> Inventory.add("apple", 30)
  |> Inventory.add("banana", 12)
  |> Inventory.add("apple", 5)

IO.puts("Total: #{Inventory.total(inv)}")
Inventory.report(inv)

case Inventory.remove(inv, "banana", 20) do
  {:ok, _} -> IO.puts("removed")
  {:error, reason} -> IO.puts("error: #{reason}")
end
