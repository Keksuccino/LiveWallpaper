//! Clipping groups of puppets: which parts draw where, and which render the masks, as Wallpaper
//! Engine plans them (see `NOTES.md`, "Puppet clipping").
//!
//! A group's target parts show only where its mask parts cover. The mask is every part from the
//! group's first mask part to its last in draw order, except the group's own targets, rendered
//! as coverage into a buffer the size of the surface. The targets then draw with their alpha
//! times the mask under each pixel: right after the last mask part, or (group flag 8) at their
//! own places in the draw order. Flag 4 hides the mask parts themselves.
//!
//! A group whose mask parts are all targets of another group is nested in it: its mask is
//! multiplied by its parent's, and that by the grandparent's, and so on.

use crate::puppet::Puppet;

/// One step of drawing a clipped puppet. Index ranges are in the index buffer as ordered by the
/// parts' draw order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Render clipping group `g`'s mask.
    Mask(usize),
    /// Draw `count` indices from `first`, clipped by `group`'s mask if any.
    Draw { first: usize, count: usize, group: Option<usize> },
}

/// Group flags.
const HIDE_MASKS: u32 = 4;
const IN_PLACE: u32 = 8;

/// The steps drawing `model`'s parts in the order `parts` (indices into `model.segments`).
pub fn plan(model: &Puppet, parts: &[usize]) -> Vec<Step> {
    let all = Step::Draw { first: 0, count: model.indices.len(), group: None };
    let ranges = model.segments.len();
    if model.clip_groups.is_empty() || parts.len() != ranges {
        return vec![all];
    }
    let (pos, offset) = positions(model, parts);
    let groups: Vec<usize> = (0..model.clip_groups.len()).filter(|&g| !model.clip_groups[g].masks.is_empty()).collect();
    let mut target_of = vec![None; ranges];
    let mut hidden = vec![false; ranges];
    for &g in &groups {
        let group = &model.clip_groups[g];
        for &t in &group.targets {
            target_of[t].get_or_insert(g);
        }
        if group.flags & HIDE_MASKS != 0 {
            for &m in &group.masks {
                hidden[m] = true;
            }
        }
    }
    let last_mask = |g: usize| model.clip_groups[g].masks.iter().map(|&m| pos[m]).max().unwrap_or(0);
    // The parts in the order they draw, each with the group clipping it.
    let mut order: Vec<(usize, Option<usize>)> = Vec::with_capacity(parts.len());
    for (p, &range) in parts.iter().enumerate() {
        match target_of[range] {
            Some(g) if model.clip_groups[g].flags & IN_PLACE != 0 => order.push((p, Some(g))),
            Some(_) => {}
            None if hidden[range] => {}
            None => order.push((p, None)),
        }
        for &g in groups.iter().filter(|&&g| model.clip_groups[g].flags & IN_PLACE == 0 && last_mask(g) == p) {
            let mut targets: Vec<usize> = model.clip_groups[g]
                .targets
                .iter()
                .filter(|&&t| target_of[t] == Some(g))
                .map(|&t| pos[t])
                .collect();
            targets.sort_unstable();
            order.extend(targets.into_iter().map(|t| (t, Some(g))));
        }
    }
    let mut steps = Vec::new();
    let mut mask = None;
    let mut run: Option<(usize, usize, Option<usize>)> = None;
    for (p, group) in order {
        let count = model.segments[parts[p]].index_count as usize;
        if let Some((first, n, g)) = run {
            if g == group && first + n == offset[p] {
                run = Some((first, n + count, g));
                continue;
            }
            steps.push(Step::Draw { first, count: n, group: g });
        }
        if group.is_some() && group != mask {
            steps.push(Step::Mask(group.unwrap_or(0)));
            mask = group;
        }
        run = Some((offset[p], count, group));
    }
    if let Some((first, count, group)) = run {
        steps.push(Step::Draw { first, count, group });
    }
    steps
}

/// The index ranges group `g`'s mask renders: every part from its first mask part to its last in
/// draw order, except its own targets.
pub fn mask_ranges(model: &Puppet, parts: &[usize], g: usize) -> Vec<(usize, usize)> {
    let group = &model.clip_groups[g];
    let (pos, offset) = positions(model, parts);
    let (Some(first), Some(last)) = (group.masks.iter().map(|&m| pos[m]).min(), group.masks.iter().map(|&m| pos[m]).max())
    else {
        return Vec::new();
    };
    let mut out: Vec<(usize, usize)> = Vec::new();
    for (p, &range) in parts.iter().enumerate().take(last + 1).skip(first) {
        if group.targets.contains(&range) {
            continue;
        }
        let count = model.segments[range].index_count as usize;
        match out.last_mut() {
            Some((start, n)) if *start + *n == offset[p] => *n += count,
            _ => out.push((offset[p], count)),
        }
    }
    out
}

/// Each group's parent: the first other group whose targets include all of its masks. A chain
/// that comes back to a group is cut there.
pub fn parents(model: &Puppet) -> Vec<Option<usize>> {
    let groups = &model.clip_groups;
    let mut parent: Vec<Option<usize>> = (0..groups.len())
        .map(|i| {
            let masks = &groups[i].masks;
            (0..groups.len()).find(|&j| j != i && !masks.is_empty() && masks.iter().all(|m| groups[j].targets.contains(m)))
        })
        .collect();
    for i in 0..groups.len() {
        let mut at = parent[i];
        for _ in 0..groups.len() {
            match at {
                Some(j) if j == i => {
                    parent[i] = None;
                    break;
                }
                Some(j) => at = parent[j],
                None => break,
            }
        }
    }
    parent
}

/// Group `g`'s ancestors, nearest first.
pub fn ancestors(parents: &[Option<usize>], g: usize) -> Vec<usize> {
    let mut out = Vec::new();
    let mut at = parents.get(g).copied().flatten();
    while let Some(p) = at.filter(|p| !out.contains(p) && *p != g) {
        out.push(p);
        at = parents.get(p).copied().flatten();
    }
    out
}

/// Each range's position in the draw order, and each position's first index in the ordered index
/// buffer.
fn positions(model: &Puppet, parts: &[usize]) -> (Vec<usize>, Vec<usize>) {
    let mut pos = vec![0; model.segments.len()];
    let mut offset = Vec::with_capacity(parts.len());
    let mut at = 0;
    for (p, &range) in parts.iter().enumerate() {
        pos[range] = p;
        offset.push(at);
        at += model.segments[range].index_count as usize;
    }
    (pos, offset)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::puppet::{ClipGroup, Segment};

    /// Four parts of 3 indices each.
    fn model(groups: Vec<ClipGroup>) -> Puppet {
        Puppet {
            indices: vec![0; 12],
            segments: (0..4).map(|i| Segment { first_index: 3 * i, index_count: 3, ..Segment::default() }).collect(),
            clip_groups: groups,
            ..Puppet::default()
        }
    }

    #[test]
    fn without_groups_everything_draws_at_once() {
        assert_eq!(plan(&model(Vec::new()), &[0, 1, 2, 3]), vec![Step::Draw { first: 0, count: 12, group: None }]);
    }

    #[test]
    fn targets_draw_after_the_last_mask_part() {
        // Part 0 is clipped by parts 1 and 2.
        let m = model(vec![ClipGroup { targets: vec![0], masks: vec![1, 2], ..ClipGroup::default() }]);
        assert_eq!(
            plan(&m, &[0, 1, 2, 3]),
            vec![
                Step::Draw { first: 3, count: 6, group: None },
                Step::Mask(0),
                Step::Draw { first: 0, count: 3, group: Some(0) },
                Step::Draw { first: 9, count: 3, group: None },
            ]
        );
        assert_eq!(mask_ranges(&m, &[0, 1, 2, 3], 0), vec![(3, 6)]);
    }

    #[test]
    fn in_place_targets_keep_their_order_and_hidden_masks_do_not_draw() {
        let m = model(vec![ClipGroup { flags: IN_PLACE | HIDE_MASKS, targets: vec![3], masks: vec![1], ..ClipGroup::default() }]);
        assert_eq!(
            plan(&m, &[0, 1, 2, 3]),
            vec![
                Step::Draw { first: 0, count: 3, group: None },
                Step::Draw { first: 6, count: 3, group: None },
                Step::Mask(0),
                Step::Draw { first: 9, count: 3, group: Some(0) },
            ]
        );
    }

    #[test]
    fn a_group_masked_by_another_groups_targets_nests_in_it() {
        let m = model(vec![
            ClipGroup { targets: vec![1, 2], masks: vec![0], ..ClipGroup::default() },
            ClipGroup { targets: vec![3], masks: vec![1, 2], ..ClipGroup::default() },
        ]);
        let nested = parents(&m);
        assert_eq!(nested, vec![None, Some(0)]);
        assert_eq!(ancestors(&nested, 1), vec![0]);
        // Groups masking each other's targets would loop: the loop is cut at the first.
        let m = model(vec![
            ClipGroup { targets: vec![1], masks: vec![0], ..ClipGroup::default() },
            ClipGroup { targets: vec![0], masks: vec![1], ..ClipGroup::default() },
        ]);
        assert_eq!(parents(&m), vec![None, Some(0)]);
    }

    #[test]
    fn the_mask_spans_the_parts_between_its_first_and_last_mask() {
        // Masks 0 and 3 in draw order; part 1 is a target, part 2 lies between.
        let m = model(vec![ClipGroup { targets: vec![1], masks: vec![0, 3], ..ClipGroup::default() }]);
        assert_eq!(mask_ranges(&m, &[0, 1, 2, 3], 0), vec![(0, 3), (6, 6)]);
    }
}
