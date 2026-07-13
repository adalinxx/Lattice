# Architecture PR checklist

- [ ] Availability, validity, canonicity, durability, authority, and evidence stay distinct.
- [ ] Parent canonical transitions have no child consumers.
- [ ] Every ingress path maps the same verified candidate to the same decision.
- [ ] Valid side admission is not labeled invalid.
- [ ] Local storage or availability failure cannot penalize a peer.
- [ ] Restart reconstructs the live fork-choice inputs.
- [ ] Complete Volumes remain atomic availability units.
- [ ] New abstractions enforce a boundary or create an independent correctness seam.
