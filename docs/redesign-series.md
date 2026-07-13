# Coordinated redesign series

This PR is the normative and consensus-facing foundation for companion changes in cashew, VolumeBroker, Tally, Ivy, and lattice-node.

The new chain-local admission API is additive. The legacy API remains as a migration oracle while downstream paths move differentially and prove equivalence. The lattice-node integration branch consumes this branch directly and validates the complete stack.
