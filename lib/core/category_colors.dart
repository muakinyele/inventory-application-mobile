import 'package:flutter/material.dart';

/// The fixed swatch set offered when naming a category.
///
/// Categories are stored by name everywhere else in the app, so colour is kept
/// as an index into this list rather than a free-form value: the set stays
/// curated, the stored payload stays small, and an unknown index degrades to a
/// sensible default instead of an invalid colour.
const categorySwatches = <Color>[
  Color(0xFFEF4444), // red
  Color(0xFFF97316), // orange
  Color(0xFFEAB308), // yellow
  Color(0xFF4ADE80), // green
  Color(0xFF2DB39A), // teal
  Color(0xFF3B82F6), // blue
  Color(0xFF8B5CF6), // violet
  Color(0xFFEC4899), // pink
  Color(0xFF64748B), // slate
  Color(0xFF38BDF8), // sky
  Color(0xFF22C55E), // emerald
  Color(0xFFF59E0B), // amber
];

/// Swatches ordered so that consecutive picks are easy to tell apart — the
/// list is walked in this order when a category needs a colour, rather than
/// straight down [categorySwatches], where neighbours are near-duplicates.
const _assignmentOrder = <int>[5, 1, 4, 6, 11, 7, 9, 0, 3, 2, 8, 10];

/// The swatch for a category that has no explicit choice yet.
///
/// [rank] is the category's position in the workspace's list, so the first
/// few categories land on visibly different hues instead of colliding — a
/// name hash produced four near-identical pinks in practice, which made the
/// share chart unreadable.
int defaultSwatchIndex(String name, {int rank = 0}) {
  if (name.isEmpty) return 8; // slate, for "Uncategorised"
  return _assignmentOrder[rank % _assignmentOrder.length];
}

Color swatchAt(int index) =>
    categorySwatches[index.clamp(0, categorySwatches.length - 1)];
