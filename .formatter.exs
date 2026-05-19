[
  plugins: [Quokka],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  quokka: [
    autosort: [:map, :defstruct],
    only: [
      :autosort,
      :blocks,
      :configs,
      :defs,
      :deprecations,
      :module_directives,
      :pipes,
      :single_node
    ]
  ]
]
