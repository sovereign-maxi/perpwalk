[
  # Federation.Keys wraps Cartel.config() in a rescue/catch that
  # dialyzer sees as unreachable — Cartel.config()'s spec never
  # returns error and never raises. The rescue guards the real
  # runtime scenario where Cartel isn't yet booted (early
  # application init, test env with cartel supervisor disabled)
  # which dialyzer can't infer from specs alone.
  ~r"lib/perp_walk/federation/keys.ex"
]
