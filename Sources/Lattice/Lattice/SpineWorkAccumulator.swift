/// Subtree work by accumulation over canonical-spine growth, so that the common
/// admission is constant time regardless of chain length.
///
/// A block on the spine stores two numbers: `base`, its subtree total when it
/// was stamped, and `snapshot`, the accumulator's value at that moment. Its
/// subtree total is then `base + (accum - snapshot)`.
///
/// ## Why that is sound, and exactly when it stops being sound
///
/// The formula is licensed by ONE predicate: every admission since a block was
/// stamped has been a descendant of it. While that holds, `accum - snapshot` is
/// precisely the work added inside the block's subtree, so the sum is its true
/// total. The moment an admission is NOT a descendant, the block's accrual is
/// invalid and it must stop accruing — which is what leaving the spine means
/// here. `onSpine` is therefore not bookkeeping: it is the predicate that
/// licenses the formula, and a block is frozen at the instant the predicate
/// fails rather than at some later tidy-up.
///
/// ## The maintenance rule
///
/// Admitting work `w` at block X:
///
/// 1. `A0 = accum`
/// 2. Freeze every leaver at `A0`, using its pre-bump stamp. `A0` and not the
///    bumped value, because X is not their descendant and they must not see
///    `w`.
/// 3. `accum += w`
/// 4. Correct the spine blocks that are NOT ancestors-or-self of X — the suffix
///    strictly above X's deepest spine ancestor. The accumulator credited them
///    and should not have. No offset field is needed: the formula subtracts
///    `snapshot`, so `snapshot += w` undoes the credit exactly.
/// 5. Stamp each joiner at the POST-increment `accum`, with `base` set to its
///    true current subtree total.
///
/// Step 4 is an ANCESTOR test, not a height test. "Spine blocks at height >= h"
/// is the same set only while X attaches at the tip of the spine. It diverges in
/// two reachable cases: a stronger observation on a block already on the spine
/// (the height form wrongly includes X itself, which must gain the work), and a
/// sibling arriving after its canonical rival, where X attaches off-spine under
/// a fork and the suffix to correct starts above the FORK, not above X's height.
/// A height test passes the whole merged-mining measurement and is silently
/// wrong one delivery order over.
///
/// Cost: a tip extension corrects nothing and freezes nothing — one add, one
/// stamp. A displacement freezes one block. A mutation at depth corrects the
/// suffix above it, which is distance-from-tip. Measured on a 400-height
/// merged-mining sync: 800 admissions all at depth 0, 400 displacements with at
/// most one block removed, and a late restrike reaching depth 399.
///
/// This is derived state, never a durable fact: it is rebuildable from the
/// accepted graph and the proof-derived work facts, which remain authoritative.
struct SpineWorkAccumulator: Sendable {
    /// A block joining the spine, with the subtree total it already carries.
    struct Joiner: Sendable {
        let hash: String
        let base: WorkSum

        init(hash: String, base: WorkSum) {
            self.hash = hash
            self.base = base
        }
    }

    private var accum: WorkSum = .zero
    private var base: [String: WorkSum] = [:]
    private var snapshot: [String: WorkSum] = [:]
    private var direct: [String: WorkSum] = [:]
    private var onSpine: Set<String> = []

    static var empty: SpineWorkAccumulator { SpineWorkAccumulator() }

    func isOnSpine(_ hash: String) -> Bool { onSpine.contains(hash) }

    func contains(_ hash: String) -> Bool {
        onSpine.contains(hash) || direct[hash] != nil
    }

    /// Subtree work for any tracked block. On-spine blocks are derived from the
    /// accumulator; off-spine blocks hold their total directly, because their
    /// accrual predicate does not hold.
    func subtreeWork(_ hash: String) -> WorkSum? {
        guard onSpine.contains(hash) else { return direct[hash] }
        guard let stamped = base[hash],
              let taken = snapshot[hash],
              // `accum` only grows and a stamp is a past value of it, so this
              // cannot fail. It is a guard and not an assumption because
              // `WorkSum` must not wrap or saturate: either would erase the
              // strict ordering between two branches.
              let grown = accum.subtracting(taken) else { return nil }
        return stamped + grown
    }

    /// One admission. Returns false rather than mutating partially if any block
    /// named is inconsistent with the state, so a malformed call cannot leave a
    /// half-applied accumulator.
    @discardableResult
    mutating func apply(
        work: WorkSum,
        leaving: [String] = [],
        correctingNonAncestors: [String] = [],
        joining: [Joiner] = []
    ) -> Bool {
        // Validate before mutating: this structure has no undo.
        for hash in leaving where !onSpine.contains(hash) { return false }
        for hash in leaving {
            guard base[hash] != nil, snapshot[hash] != nil else { return false }
        }

        let preIncrement = accum

        // Freeze leavers at the PRE-increment accumulator. The block being
        // admitted is not their descendant, so they must not see its work.
        for hash in leaving {
            guard let stamped = base[hash],
                  let taken = snapshot[hash],
                  let grown = preIncrement.subtracting(taken) else { return false }
            direct[hash] = stamped + grown
            base.removeValue(forKey: hash)
            snapshot.removeValue(forKey: hash)
            onSpine.remove(hash)
        }

        accum = accum + work

        // Undo the credit for spine blocks that are not ancestors-or-self of the
        // admitted block. A block that was also a leaver is already frozen and
        // off-spine, so it is skipped — the two steps collapse into the freeze
        // in the common displacement case.
        for hash in correctingNonAncestors where onSpine.contains(hash) {
            snapshot[hash] = (snapshot[hash] ?? .zero) + work
        }

        // Stamp joiners at the POST-increment accumulator. Stamping before the
        // increment would make a block's own work count twice: its `base`
        // already contains it, and `accum - snapshot` would contain it again.
        for joiner in joining {
            direct.removeValue(forKey: joiner.hash)
            base[joiner.hash] = joiner.base
            snapshot[joiner.hash] = accum
            onSpine.insert(joiner.hash)
        }
        return true
    }

    /// Set an off-spine block's directly-maintained total. Side subtrees do not
    /// satisfy the accrual predicate, so they carry their own totals.
    mutating func setDirect(_ hash: String, total: WorkSum) {
        guard !onSpine.contains(hash) else { return }
        direct[hash] = total
    }

#if DEBUG
    /// Every on-spine stamp is a past value of a monotone accumulator, so the
    /// subtraction the formula performs can never underflow. A violation means
    /// a stamp was taken from something other than `accum`, or `accum` moved
    /// backwards — either of which silently breaks fork-choice ordering.
    var debugStampsAreInThePast: Bool {
        for hash in onSpine {
            guard let taken = snapshot[hash],
                  accum.subtracting(taken) != nil else { return false }
        }
        return true
    }

    var debugAccumulator: WorkSum { accum }

    var debugOnSpineCount: Int { onSpine.count }
#endif
}
