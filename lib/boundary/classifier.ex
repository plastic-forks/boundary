defmodule Boundary.Classifier do
  @moduledoc false

  @type t :: %{boundaries: %{Boundary.name() => Boundary.t()}, modules: %{module() => Boundary.name()}}

  @spec new :: t
  def new, do: %{boundaries: %{}, modules: %{}}

  @spec delete(t, atom) :: t
  def delete(classifier, app) do
    boundaries_to_delete =
      classifier.boundaries
      |> Map.values()
      |> Stream.filter(&(&1.app == app))
      |> Enum.map(& &1.name)

    boundaries = Map.drop(classifier.boundaries, boundaries_to_delete)

    modules =
      for {_, boundary} = entry <- classifier.modules,
          Map.has_key?(boundaries, boundary),
          do: entry,
          into: %{}

    %{classifier | boundaries: boundaries, modules: modules}
  end

  @spec classify(t, [module], [Boundary.t()]) :: t
  def classify(classifier, modules, boundaries) do
    trie = build_trie(boundaries)

    classifier = %{
      classifier
      | boundaries:
          trie
          |> boundaries()
          |> Stream.map(fn
            %{top_level?: true} = boundary -> %{boundary | ancestors: []}
            %{top_level?: false} = boundary -> boundary
          end)
          |> Stream.map(&Map.delete(&1, :top_level?))
          |> Enum.into(classifier.boundaries, &{&1.name, &1})
    }

    for module <- modules,
        boundary = find_boundary(trie, module),
        reduce: classifier do
      classifier -> Map.update!(classifier, :modules, &Map.put(&1, module, boundary.name))
    end
  end

  defp boundaries(trie, ancestors \\ []) do
    ancestors = if is_nil(trie.boundary), do: ancestors, else: [trie.boundary.name | ancestors]

    child_boundaries =
      trie.children
      |> Map.values()
      |> Enum.flat_map(&boundaries(&1, ancestors))

    if is_nil(trie.boundary),
      do: child_boundaries,
      else: [Map.put(trie.boundary, :ancestors, tl(ancestors)) | child_boundaries]
  end

  defp build_trie(boundaries), do: Enum.reduce(boundaries, new_trie(), &add_boundary(&2, &1))

  defp new_trie, do: %{boundary: nil, children: %{}}

  defp find_boundary(trie, module) when is_atom(module) do
    case Boundary.Definition.classified_to(module) do
      nil ->
        find_boundary(trie, Module.split(module))

      classified_to ->
        # If we can't find `classified_to`, it's an error in definition (like e.g. classifying to a reclassified
        # boundary). This error has already been reported (see `Boundary.Definition.get/1`), and here we treat the
        # boundary as if it was not reclassified.
        find_boundary(trie, Module.split(classified_to.boundary)) || find_boundary(trie, Module.split(module))
    end
  end

  defp find_boundary(_trie, []), do: nil

  defp find_boundary(trie, [part | rest]) do
    case Map.fetch(trie.children, part) do
      {:ok, child_trie} -> find_boundary(child_trie, rest) || child_trie.boundary
      :error -> nil
    end
  end

  defp add_boundary(trie, boundary),
    do: add_boundary(trie, Module.split(boundary.name), boundary)

  defp add_boundary(trie, [], boundary), do: %{trie | boundary: boundary}

  defp add_boundary(trie, [part | rest], boundary) do
    Map.update!(
      trie,
      :children,
      fn children ->
        children
        |> Map.put_new_lazy(part, &new_trie/0)
        |> Map.update!(part, &add_boundary(&1, rest, boundary))
      end
    )
  end
end
