# Architecture PR checklist

- [ ] Availability, validity, canonicity, durability, authority, and evidence stay distinct.
- [ ] Parent canonical transitions have no child consumers.
- [ ] One Lattice process owns one chain; no recursive runtime path is introduced.
- [ ] The setup-wide root-work floor is checked before per-chain targets.
- [ ] Every carrier proves same-chain predecessor continuity.
- [ ] One root CID identifies one immutable work contribution.
- [ ] Every ingress path maps the same verified candidate to the same decision.
- [ ] Valid side admission is not labeled invalid.
- [ ] Local storage or availability failure cannot penalize a peer.
- [ ] Restart reconstructs the live fork-choice inputs.
- [ ] Complete Volumes remain atomic availability units.
- [ ] Targeted resolve and store preserve independent nested Volume boundaries.
- [ ] `StateDiff` remains local lifecycle metadata, never a `Block` field.
- [ ] New abstractions enforce a boundary or create an independent correctness seam.
