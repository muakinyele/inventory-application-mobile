import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The kinds of cell this writer emits. Anything richer — formulas, merged
/// ranges, charts — is deliberately out of scope: a report export needs
/// figures a spreadsheet can total, not a rebuilt version of the report.
enum CellKind { text, number, money, integer, percent, date, heading }

class Cell {
  const Cell(this.value, [this.kind = CellKind.text]);

  const Cell.text(String value) : this(value, CellKind.text);
  const Cell.heading(String value) : this(value, CellKind.heading);
  const Cell.number(num value) : this(value, CellKind.number);
  const Cell.money(num value) : this(value, CellKind.money);
  const Cell.integer(num value) : this(value, CellKind.integer);

  /// Takes a fraction — 0.42 renders as 42%.
  const Cell.percent(num value) : this(value, CellKind.percent);

  const Cell.date(DateTime value) : this(value, CellKind.date);

  static const blank = Cell('');

  final Object? value;
  final CellKind kind;
}

class Sheet {
  Sheet(this.name, {this.columnWidths = const []});

  /// Excel refuses these characters in a sheet name, and silently truncates
  /// past 31 — so the name is sanitised rather than left to corrupt the file.
  final String name;

  final List<double> columnWidths;
  final List<List<Cell>> rows = [];

  void add(List<Cell> row) => rows.add(row);
  void addBlank() => rows.add(const []);
}

/// Writes a genuine .xlsx — an OOXML package, not a CSV wearing the
/// extension, so Excel, Numbers and Sheets all open it with real types:
/// money right-aligned and summable, dates as dates, percentages as
/// percentages.
///
/// Hand-rolled rather than taken from a package because the one obvious
/// choice pins `xml <7` and collides with the PDF library already here, and
/// the alternative that fits is commercially licensed. The format needed for
/// a report is a small, stable corner of the spec.
///
/// Strings are written inline rather than through a shared-strings table.
/// That costs some bytes on repetition and saves a whole part plus its
/// bookkeeping; a report is tens of kilobytes either way.
Uint8List buildXlsx(List<Sheet> sheets) {
  assert(sheets.isNotEmpty, 'a workbook needs at least one sheet');
  final archive = Archive();

  void add(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('[Content_Types].xml', _contentTypes(sheets.length));
  add('_rels/.rels', _rootRels);
  add('xl/workbook.xml', _workbook(sheets));
  add('xl/_rels/workbook.xml.rels', _workbookRels(sheets.length));
  add('xl/styles.xml', _styles);
  for (final (index, sheet) in sheets.indexed) {
    add('xl/worksheets/sheet${index + 1}.xml', _sheet(sheet));
  }

  // Store-only would also open, but a report of any size compresses to a
  // fraction: this is XML.
  final zipped = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipped);
}

// --- Parts ------------------------------------------------------------------

String _contentTypes(int sheetCount) {
  final overrides = [
    for (var i = 1; i <= sheetCount; i++)
      '<Override PartName="/xl/worksheets/sheet$i.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.'
          'spreadsheetml.worksheet+xml"/>',
  ].join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '$overrides'
      '</Types>';
}

const _rootRels =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>';

String _workbook(List<Sheet> sheets) {
  final entries = [
    for (final (index, sheet) in sheets.indexed)
      '<sheet name="${_attr(_sheetName(sheet.name))}" sheetId="${index + 1}" r:id="rId${index + 1}"/>',
  ].join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>$entries</sheets>'
      '</workbook>';
}

String _workbookRels(int sheetCount) {
  final entries = [
    for (var i = 1; i <= sheetCount; i++)
      '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>',
    '<Relationship Id="rId${sheetCount + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
  ].join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '$entries</Relationships>';
}

/// Style indices, in the order the cellXfs below declares them. Kept as
/// constants because a wrong index silently formats a column as something
/// else rather than failing.
const _styleDefault = 0;
const _styleHeading = 1;
const _styleMoney = 2;
const _styleInteger = 3;
const _stylePercent = 4;
const _styleDate = 5;

/// Two custom number formats plus built-ins. 164 is the first id available to
/// a document; anything below 164 is reserved by the spec.
const _styles =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="2">'
    '<numFmt numFmtId="164" formatCode="#,##0.00"/>'
    '<numFmt numFmtId="165" formatCode="0.0%"/>'
    '</numFmts>'
    '<fonts count="2">'
    '<font><sz val="11"/><name val="Calibri"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/></font>'
    '</fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="6">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

String _sheet(Sheet sheet) {
  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    );

  if (sheet.columnWidths.isNotEmpty) {
    buffer.write('<cols>');
    for (final (index, width) in sheet.columnWidths.indexed) {
      buffer.write(
        '<col min="${index + 1}" max="${index + 1}" '
        'width="${width.toStringAsFixed(2)}" customWidth="1"/>',
      );
    }
    buffer.write('</cols>');
  }

  buffer.write('<sheetData>');
  for (final (rowIndex, row) in sheet.rows.indexed) {
    final rowNumber = rowIndex + 1;
    if (row.isEmpty) {
      buffer.write('<row r="$rowNumber"/>');
      continue;
    }
    buffer.write('<row r="$rowNumber">');
    for (final (colIndex, cell) in row.indexed) {
      buffer.write(_cell(cell, _columnName(colIndex), rowNumber));
    }
    buffer.write('</row>');
  }
  buffer.write('</sheetData></worksheet>');
  return buffer.toString();
}

String _cell(Cell cell, String column, int row) {
  final ref = '$column$row';
  final value = cell.value;

  switch (cell.kind) {
    case CellKind.text:
    case CellKind.heading:
      final text = value?.toString() ?? '';
      if (text.isEmpty) return '';
      final style = cell.kind == CellKind.heading
          ? _styleHeading
          : _styleDefault;
      return '<c r="$ref" s="$style" t="inlineStr"><is><t xml:space="preserve">'
          '${_escape(text)}</t></is></c>';

    case CellKind.number:
    case CellKind.money:
    case CellKind.integer:
    case CellKind.percent:
      if (value is! num || !value.isFinite) return '';
      final style = switch (cell.kind) {
        CellKind.money => _styleMoney,
        CellKind.integer => _styleInteger,
        CellKind.percent => _stylePercent,
        _ => _styleDefault,
      };
      return '<c r="$ref" s="$style"><v>${_number(value)}</v></c>';

    case CellKind.date:
      if (value is! DateTime) return '';
      return '<c r="$ref" s="$_styleDate"><v>${_serialDate(value)}</v></c>';
  }
}

/// Excel stores a date as days since 1899-12-30. The two-day offset from the
/// obvious epoch absorbs a leap-year bug Lotus 1-2-3 shipped and Excel keeps
/// for compatibility — 1900 is treated as a leap year, which it was not.
int _serialDate(DateTime date) {
  final epoch = DateTime(1899, 12, 30);
  final day = DateTime(date.year, date.month, date.day);
  return day.difference(epoch).inDays;
}

String _number(num value) {
  if (value is int) return '$value';
  // Trailing '.0' is valid but noisy in the XML, and whole money reads better
  // in the formula bar without it.
  return value == value.roundToDouble() && value.abs() < 1e15
      ? '${value.toInt()}'
      : '$value';
}

/// A1, B1 ... Z1, AA1. Only ever asked for the column count of a report, but
/// written generally so a wide sheet does not silently produce nonsense.
String _columnName(int index) {
  var n = index;
  final name = StringBuffer();
  while (true) {
    name.write(String.fromCharCode(65 + n % 26));
    n = n ~/ 26 - 1;
    if (n < 0) break;
  }
  return String.fromCharCodes(name.toString().codeUnits.reversed);
}

/// Excel rejects : \ / ? * [ ] in a sheet name and caps it at 31 characters.
/// A name that breaks either rule makes the whole workbook unopenable, so it
/// is corrected here rather than trusted.
String _sheetName(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
  final safe = cleaned.isEmpty ? 'Sheet' : cleaned;
  return safe.length <= 31 ? safe : safe.substring(0, 31);
}

String _escape(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x26:
        out.write('&amp;');
      case 0x3C:
        out.write('&lt;');
      case 0x3E:
        out.write('&gt;');
      default:
        // Control characters are illegal in XML 1.0 and make the package
        // unreadable; tab, newline and carriage return are the exceptions.
        if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
          continue;
        }
        out.writeCharCode(rune);
    }
  }
  return out.toString();
}

String _attr(String value) => _escape(value).replaceAll('"', '&quot;');
