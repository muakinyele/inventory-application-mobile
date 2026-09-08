import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';

/// One category's contribution to a measure.
class ChartSlice {
  const ChartSlice({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;
}

/// Ranked bars for one measure across categories.
///
/// A single measure is a magnitude comparison, so it uses one hue rather than
/// a colour per bar — the axis labels carry identity, and every bar is
/// directly labelled with its value.
class CategoryBarChart extends StatelessWidget {
  const CategoryBarChart({
    super.key,
    required this.slices,
    required this.formatValue,
  });

  final List<ChartSlice> slices;
  final String Function(double) formatValue;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (slices.isEmpty) return _NoData(message: 'Nothing to compare yet.');

    final max = slices.fold<double>(0, (m, s) => s.value > m ? s.value : m);
    // Headroom so the tallest bar's label is never flush with the top.
    final ceiling = max <= 0 ? 1.0 : max * 1.22;

    return SizedBox(
      height: 260,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: ceiling,
          minY: 0,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => p.ink,
              tooltipBorderRadius: BorderRadius.circular(Radii.control),
              getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                '${slices[group.x].label}\n',
                TextStyle(
                  color: p.plane,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
                children: [
                  TextSpan(
                    text: formatValue(rod.toY),
                    style: TextStyle(
                      color: p.plane,
                      fontWeight: FontWeight.w400,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: ceiling / 4,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: p.line, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 52,
                interval: ceiling / 4,
                getTitlesWidget: (value, meta) {
                  if (value >= meta.max) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      compactNumber(value),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, color: p.inkMuted),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= slices.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      // Wide enough for "Accessories" and "Raw Materials" to
                      // break between words rather than mid-word.
                      width: 82,
                      child: Text(
                        slices[index].label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.25,
                          color: p.inkSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (final (index, slice) in slices.indexed)
              BarChartGroupData(
                x: index,
                barRods: [
                  BarChartRodData(
                    toY: slice.value,
                    color: p.accent,
                    width: 26,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Share of a total across categories.
///
/// A donut is only honest for part-to-whole at a glance, so it is capped at six
/// segments (the tail folds into "Other") and always ships beside a legend
/// carrying the name, value and share — colour is never the only channel.
class CategoryDonutChart extends StatefulWidget {
  const CategoryDonutChart({
    super.key,
    required this.slices,
    required this.total,
    required this.formatValue,
    required this.centerLabel,
  });

  final List<ChartSlice> slices;
  final double total;
  final String Function(double) formatValue;
  final String centerLabel;

  @override
  State<CategoryDonutChart> createState() => _CategoryDonutChartState();
}

class _CategoryDonutChartState extends State<CategoryDonutChart> {
  /// Bounds on the drawn circle. The floor keeps it readable on a phone; the
  /// ceiling stops it ballooning to fill a wide desktop card.
  static const _minDiameter = 240.0;
  static const _maxDiameter = 340.0;

  /// Ring thickness as a fraction of the diameter. Thin enough to leave a
  /// generous hole for the total, thick enough to carry a "69%" label.
  static const _ringFraction = 0.16;

  /// How far the touched slice grows outward.
  static const _touchGrowth = 6.0;

  int _touched = -1;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (widget.slices.isEmpty || widget.total <= 0) {
      return _NoData(message: 'Nothing to break down yet.');
    }

    double share(ChartSlice s) => s.value / widget.total * 100;

    // Sized from the space the card actually gives it rather than a fixed
    // height. The centre has to hold a full currency total — which for a
    // six-figure inventory is a long string — so the hole is derived from the
    // ring rather than the other way round, and the text is fitted to the
    // square that inscribes it. A fixed 58pt hole used to let the total spill
    // out over the arcs and collide with the slice labels.
    final chart = LayoutBuilder(
      builder: (context, constraints) {
        final diameter = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(_minDiameter, _maxDiameter)
            : _maxDiameter;
        final outer = diameter / 2;
        final ring = diameter * _ringFraction;
        // The touched slice grows outward, so the resting radius leaves room
        // for it and the chart never overflows its own box.
        final centerRadius = outer - ring - _touchGrowth;
        // Side of the largest square inside the hole, less a little padding.
        final holeWidth = centerRadius * 1.42;

        return SizedBox(
          height: diameter,
          width: diameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: centerRadius,
                  startDegreeOffset: -90,
                  pieTouchData: PieTouchData(
                    touchCallback: (event, response) {
                      setState(() {
                        _touched = event.isInterestedForInteractions
                            ? response?.touchedSection?.touchedSectionIndex ??
                                  -1
                            : -1;
                      });
                    },
                  ),
                  sections: [
                    for (final (index, slice) in widget.slices.indexed)
                      PieChartSectionData(
                        value: slice.value,
                        color: slice.color,
                        radius: _touched == index ? ring + _touchGrowth : ring,
                        // Below ~7% the label cannot sit inside the arc legibly;
                        // the legend carries those values instead.
                        showTitle: share(slice) >= 7,
                        title: '${share(slice).round()}%',
                        titleStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          shadows: [
                            Shadow(blurRadius: 2, color: Colors.black38),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: holeWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Scaled down rather than clipped or wrapped: a total is only
                    // useful if the whole figure is legible, and how long it runs
                    // depends on the currency and the size of the business.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _touched >= 0
                            ? widget.formatValue(widget.slices[_touched].value)
                            : widget.formatValue(widget.total),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          color: p.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _touched >= 0
                          ? widget.slices[_touched].label
                          : widget.centerLabel,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.inkMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    return Column(
      children: [
        chart,
        const SizedBox(height: Insets.lg),
        for (final (index, slice) in widget.slices.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: slice.color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    slice.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: _touched == index
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: p.inkSecondary,
                    ),
                  ),
                ),
                Text(
                  '${share(slice).toStringAsFixed(share(slice) < 10 ? 1 : 0)}%',
                  style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                ),
                const SizedBox(width: Insets.md),
                SizedBox(
                  width: 116,
                  // Same reasoning as the centre: shrink to fit rather than
                  // wrap. At 92pt a figure like the one above broke across two
                  // lines and split the number in half.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      widget.formatValue(slice.value),
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class DayFlow {
  const DayFlow({
    required this.day,
    required this.stockIn,
    required this.stockOut,
  });
  final DateTime day;
  final int stockIn;

  /// Stored positive; drawn below the baseline.
  final int stockOut;
}

/// Stock in and out per day, drawn as a diverging column chart around a zero
/// baseline — receipts above, issues below — so direction reads without
/// decoding a legend, though one is still provided.
class FlowChart extends StatelessWidget {
  const FlowChart({super.key, required this.days});

  final List<DayFlow> days;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasFlow = days.any((d) => d.stockIn > 0 || d.stockOut > 0);
    if (!hasFlow) {
      return _NoData(message: 'No stock has moved in the last two weeks.');
    }

    final peak = days.fold<double>(0, (m, d) {
      final local = d.stockIn > d.stockOut ? d.stockIn : d.stockOut;
      return local > m ? local.toDouble() : m;
    });
    final bound = (peak <= 0 ? 1.0 : peak) * 1.25;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _LegendDot(color: p.good, label: 'Stock in'),
            const SizedBox(width: Insets.lg),
            _LegendDot(color: p.critical, label: 'Stock out'),
          ],
        ),
        const SizedBox(height: Insets.lg),
        SizedBox(
          height: 220,
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceBetween,
              maxY: bound,
              minY: -bound,
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => p.ink,
                  tooltipBorderRadius: BorderRadius.circular(Radii.control),
                  getTooltipItem: (group, _, rod, _) {
                    final day = days[group.x];
                    final isIn = rod.toY >= 0;
                    return BarTooltipItem(
                      '${dayLabel(day.day)}\n',
                      TextStyle(
                        color: p.plane,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                      children: [
                        TextSpan(
                          text: isIn
                              ? '+${number(day.stockIn)} in'
                              : '-${number(day.stockOut)} out',
                          style: TextStyle(color: p.plane, fontSize: 12.5),
                        ),
                      ],
                    );
                  },
                ),
              ),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: bound / 2,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: value == 0 ? p.lineStrong : p.line,
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: bound / 2,
                    getTitlesWidget: (value, meta) {
                      if (value.abs() >= meta.max) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          compactNumber(value.abs()),
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 11, color: p.inkMuted),
                        ),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 || index >= days.length) {
                        return const SizedBox.shrink();
                      }
                      // Every other day, so labels never collide.
                      if (index.isOdd) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          shortDay(days[index].day),
                          style: TextStyle(fontSize: 10.5, color: p.inkMuted),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (final (index, day) in days.indexed)
                  BarChartGroupData(
                    x: index,
                    groupVertically: true,
                    barsSpace: 0,
                    barRods: [
                      if (day.stockIn > 0)
                        BarChartRodData(
                          fromY: 0,
                          toY: day.stockIn.toDouble(),
                          color: p.good,
                          width: 9,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                      if (day.stockOut > 0)
                        BarChartRodData(
                          fromY: 0,
                          toY: -day.stockOut.toDouble(),
                          color: p.critical,
                          width: 9,
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(3),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12.5, color: p.inkSecondary)),
      ],
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 140,
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, color: p.inkMuted),
        ),
      ),
    );
  }
}
