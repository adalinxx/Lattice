# Coordinated redesign series

## Executable Lattice boundary

This PR is the normative and consensus-facing foundation for companion changes
in cashew, VolumeBroker, Tally, Ivy, and lattice-node. It removes the legacy
Lattice ingress rather than leaving it as a migration oracle: admission consumes
trusted runtime context, returns typed availability/validity/temporal/missing-body
outcomes, requires durable preparation, and operates on a path-keyed child-root
forest.

The node-facing responsibilities that remain are intentional orchestration
handoffs, not alternate consensus paths. They are listed in the [migration
conflict register](migration-conflict-register.md).
