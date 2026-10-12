//! Selection helpers for a keyboard copy mode. Copy mode is a selection:
//! a one-cell selection is the copy cursor, and the `adjust_selection`
//! binding action moves its end. These helpers place a selection at a
//! viewport cell, report the moving end in viewport coordinates, and widen
//! a selection to whole lines. They are pure over a screen, so they are
//! tested without a surface; the caller holds the terminal lock.
//!
//! Ported from manaflow-ai/ghostty-next pull request 15 (MIT).
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const lib = @import("../lib/main.zig");

const Screen = terminal.Screen;
const Selection = terminal.Selection;

/// The moving end of a selection, in viewport cells.
pub const Endpoint = extern struct {
    /// Row relative to the viewport's top row: negative above the
    /// viewport, `rows` or more below it.
    row: i32,
    /// Column of the end cell's glyph lead.
    column: u16,
    /// 2 for a wide glyph, 1 otherwise.
    width_cells: u16,
    /// The end cell is visible.
    in_viewport: bool,
};

/// The glyph lead and width of the cell at `pin`; a wide tail or a
/// spacer head resolves to its wide glyph.
fn canonicalCell(pin: terminal.Pin) ?struct {
    pin: terminal.Pin,
    width_cells: u16,
} {
    return switch (pin.rowAndCell().cell.wide) {
        .wide => .{ .pin = pin, .width_cells = 2 },
        .spacer_tail => .{ .pin = pin.left(1), .width_cells = 2 },
        .narrow => .{ .pin = pin, .width_cells = 1 },
        .spacer_head => cell: {
            var it = pin.cellIterator(.right_down, null);
            _ = it.next();
            const next = it.next() orelse return null;
            if (next.rowAndCell().cell.wide != .wide) return null;
            break :cell .{ .pin = next, .width_cells = 2 };
        },
    };
}

/// A one-cell selection at a visible cell (the copy cursor). A wide tail
/// or a spacer head resolves to the wide glyph. Null outside the viewport.
pub fn cellSelection(screen: *const Screen, column: u16, row: u16) ?Selection {
    if (column >= screen.pages.cols or row >= screen.pages.rows) return null;
    const pin = screen.pages.pin(.{ .viewport = .{ .x = column, .y = row } }) orelse return null;
    const cell = canonicalCell(pin) orelse return null;
    return Selection.init(cell.pin, cell.pin, false);
}

/// A one-cell selection at the terminal cursor, where copy mode starts.
pub fn cursorSelection(screen: *const Screen) ?Selection {
    const cell = canonicalCell(screen.cursor.page_pin.*) orelse return null;
    return Selection.init(cell.pin, cell.pin, false);
}

/// Vim word motions: `w`, `b` and `e`.
/// Sync with: ghostty_word_motion_e
pub const WordMotion = enum(c_int) {
    next_start,
    prev_start,
    next_end,

    test "ghostty.h WordMotion" {
        try lib.checkGhosttyHEnum(WordMotion, "GHOSTTY_WORD_MOTION_");
    }
};

const Class = enum { blank, punct, word };

fn classOf(pin: terminal.Pin, boundary: []const u21) Class {
    const rac = pin.rowAndCell();
    // A wide glyph's tail belongs to the glyph on its left.
    if (rac.cell.wide == .spacer_tail) return classOf(pin.left(1), boundary);
    if (!rac.cell.hasText()) return .blank;
    const cp = rac.cell.content.codepoint.data;
    if (cp == ' ' or cp == '\t') return .blank;
    return if (std.mem.indexOfScalar(u21, boundary, cp) != null) .punct else .word;
}

/// True if a hard line break lies between `pin` and the cell after it.
/// A soft-wrapped row continues on the next row, so words cross it.
fn breakAfter(pin: terminal.Pin) bool {
    return pin.x == pin.node.cols() - 1 and !pin.rowAndCell().row.wrap;
}

/// The selection with its moving end moved by a word motion. `boundary`
/// is `selection-word-chars`, the same split as double-click selection.
/// Null when no word lies in that direction.
pub fn wordMotion(sel: Selection, motion: WordMotion, boundary: []const u21) ?Selection {
    const end = switch (motion) {
        .next_start => nextWordStart(sel.end(), boundary),
        .prev_start => wordEdge(sel.end(), .left_up, boundary),
        .next_end => wordEdge(sel.end(), .right_down, boundary),
    } orelse return null;
    return Selection.init(sel.start(), end, false);
}

fn nextWordStart(pin: terminal.Pin, boundary: []const u21) ?terminal.Pin {
    const start_class = classOf(pin, boundary);
    var seen_blank = start_class == .blank;
    var it = pin.cellIterator(.right_down, null);
    var prev = it.next().?;
    while (it.next()) |p| {
        if (breakAfter(prev)) seen_blank = true;
        const class = classOf(p, boundary);
        if (class == .blank) {
            seen_blank = true;
        } else if (seen_blank or class != start_class) {
            return p;
        }
        prev = p;
    }
    return null;
}

/// `b` (left_up) and `e` (right_down): skip blanks, then go to the far edge
/// of the next run of cells with one class.
fn wordEdge(
    pin: terminal.Pin,
    direction: terminal.PageList.Direction,
    boundary: []const u21,
) ?terminal.Pin {
    var target: ?terminal.Pin = null;
    var target_class: Class = .blank;
    var it = pin.cellIterator(direction, null);
    var prev = it.next().?;
    while (it.next()) |p| {
        const crossed = switch (direction) {
            .right_down => breakAfter(prev),
            .left_up => breakAfter(p),
        };
        const class = classOf(p, boundary);
        if (target != null) {
            if (crossed or class != target_class) break;
            target = p;
        } else if (class != .blank) {
            target = p;
            target_class = class;
        }
        prev = p;
    }
    return target;
}

/// Where the selection's moving end is relative to the viewport.
pub fn endpoint(screen: *const Screen, sel: Selection) Endpoint {
    const end = sel.end();
    const cell = canonicalCell(end);
    const lead = if (cell) |c| c.pin else end;
    const top = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)).?.screen.y;
    const y = screen.pages.pointFromPin(.screen, lead).?.screen.y;
    const delta: i64 = @as(i64, @intCast(y)) - @as(i64, @intCast(top));
    const row: i32 = @intCast(std.math.clamp(
        delta,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
    return .{
        .row = row,
        .column = @intCast(lead.x),
        .width_cells = if (cell) |c| c.width_cells else 1,
        .in_viewport = row >= 0 and row < screen.pages.rows,
    };
}

/// The selection widened to whole rows: the anchor (start) row and the
/// moving end's row, keeping the direction so `adjust` keeps moving the end.
pub fn linewise(screen: *const Screen, sel: Selection) Selection {
    const last: terminal.size.CellCountInt = screen.pages.cols - 1;
    var start = sel.start();
    var end = sel.end();
    const start_y = screen.pages.pointFromPin(.screen, start).?.screen.y;
    const end_y = screen.pages.pointFromPin(.screen, end).?.screen.y;
    const forward = start_y < end_y or (start_y == end_y and start.x <= end.x);
    if (forward) {
        start.x = 0;
        end.x = last;
    } else {
        start.x = last;
        end.x = 0;
    }
    return Selection.init(start, end, false);
}

test "keyboard selection: a cell selection resolves a wide tail to its lead" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 6, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A橋B");

    const sel = cellSelection(&s, 2, 0).?;
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 1, .y = 0 } }, s.pages.pointFromPin(.screen, sel.start()).?);
    try testing.expect(sel.start().eql(sel.end()));
    const end = endpoint(&s, sel);
    try testing.expect(end.in_viewport);
    try testing.expectEqual(@as(u16, 1), end.column);
    try testing.expectEqual(@as(i32, 0), end.row);
    try testing.expectEqual(@as(u16, 2), end.width_cells);
}

test "keyboard selection: a cell outside the viewport is refused" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 4, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try testing.expect(cellSelection(&s, 4, 0) == null);
    try testing.expect(cellSelection(&s, 0, 2) == null);
}

test "keyboard selection: the end row is relative to the viewport top" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 10_000 });
    defer s.deinit();
    try s.testWriteString("one\ntwo\nthree\nfour");

    // Viewport shows "three" and "four"; select "two" one row above it.
    const two = s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    const above = endpoint(&s, Selection.init(two, two, false));
    try testing.expect(!above.in_viewport);
    try testing.expectEqual(@as(i32, -1), above.row);

    s.pages.scroll(.{ .top = {} });
    const visible = endpoint(&s, Selection.init(two, two, false));
    try testing.expect(visible.in_viewport);
    try testing.expectEqual(@as(i32, 1), visible.row);
}

test "keyboard selection: linewise widens to whole rows in both directions" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234");

    const forward = linewise(&s, Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        false,
    ));
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 0, .y = 0 } }, s.pages.pointFromPin(.screen, forward.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 4, .y = 1 } }, s.pages.pointFromPin(.screen, forward.end()).?);

    const reverse = linewise(&s, Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
        false,
    ));
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 4, .y = 2 } }, s.pages.pointFromPin(.screen, reverse.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 0, .y = 1 } }, s.pages.pointFromPin(.screen, reverse.end()).?);
}

test "keyboard selection: adjust down then linewise keeps the anchor row" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234");

    var sel = linewise(&s, cellSelection(&s, 2, 0).?);
    sel.adjust(&s, .down);
    sel = linewise(&s, sel);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 0, .y = 0 } }, s.pages.pointFromPin(.screen, sel.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 4, .y = 1 } }, s.pages.pointFromPin(.screen, sel.end()).?);
}

fn testCell(s: *const Screen, x: u16, y: u32) Selection {
    const p = s.pages.pin(.{ .screen = .{ .x = x, .y = y } }).?;
    return Selection.init(p, p, false);
}

fn testEnd(s: *const Screen, sel: ?Selection) terminal.point.Point {
    return s.pages.pointFromPin(.screen, sel.?.end()).?;
}

const test_boundary = [_]u21{ ' ', '\t', '.', ',', '(', ')' };

test "keyboard selection: cursor selection is at the terminal cursor" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ab\ncde");

    const sel = cursorSelection(&s).?;
    try testing.expectEqual(terminal.point.Point{ .screen = .{ .x = 3, .y = 1 } }, s.pages.pointFromPin(.screen, sel.start()).?);
    try testing.expect(sel.start().eql(sel.end()));
}

test "keyboard selection: w b e within a row" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo.bar  baz");
    const b = &test_boundary;
    const P = terminal.point.Point;

    // w: word -> punct -> word -> across blanks
    try testing.expectEqual(P{ .screen = .{ .x = 3, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 0, 0), .next_start, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 4, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 3, 0), .next_start, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 9, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 5, 0), .next_start, b)));

    // e: end of this word, or of the next one when already at an end
    try testing.expectEqual(P{ .screen = .{ .x = 2, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 0, 0), .next_end, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 11, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 6, 0), .next_end, b)));

    // b: start of this word, or of the previous one when already at a start
    try testing.expectEqual(P{ .screen = .{ .x = 9, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 11, 0), .prev_start, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 4, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 9, 0), .prev_start, b)));

    // Nothing after the last word, nothing before the first.
    try testing.expect(wordMotion(testCell(&s, 9, 0), .next_start, b) == null);
    try testing.expect(wordMotion(testCell(&s, 0, 0), .prev_start, b) == null);

    // The anchor stays put.
    const moved = wordMotion(testCell(&s, 0, 0), .next_end, b).?;
    try testing.expectEqual(P{ .screen = .{ .x = 0, .y = 0 } }, s.pages.pointFromPin(.screen, moved.start()).?);
}

test "keyboard selection: words follow soft wraps and stop at hard breaks" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 4, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    // "abcdef" soft-wraps after "abcd"; "gh" starts after a hard break.
    try s.testWriteString("abcdef\nghij");
    const b = &test_boundary;
    const P = terminal.point.Point;

    // e and b cross the soft wrap inside "abcdef".
    try testing.expectEqual(P{ .screen = .{ .x = 1, .y = 1 } }, testEnd(&s, wordMotion(testCell(&s, 0, 0), .next_end, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 0, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 1, 1), .prev_start, b)));

    // Row 1 ("ef") is not wrapped, so "ghij" is a new word even though
    // the cells touch: w goes there, and e from "f" lands on its end.
    try testing.expectEqual(P{ .screen = .{ .x = 0, .y = 2 } }, testEnd(&s, wordMotion(testCell(&s, 0, 0), .next_start, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 3, .y = 2 } }, testEnd(&s, wordMotion(testCell(&s, 1, 1), .next_end, b)));
}

test "keyboard selection: a full row ending at a hard break splits words" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 4, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    // "abcd" fills row 0; the hard break keeps "efgh" a separate word.
    try s.testWriteString("abcd\nefgh");
    const b = &test_boundary;
    const P = terminal.point.Point;

    try testing.expectEqual(P{ .screen = .{ .x = 3, .y = 0 } }, testEnd(&s, wordMotion(testCell(&s, 0, 0), .next_end, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 0, .y = 1 } }, testEnd(&s, wordMotion(testCell(&s, 0, 0), .next_start, b)));
    try testing.expectEqual(P{ .screen = .{ .x = 0, .y = 1 } }, testEnd(&s, wordMotion(testCell(&s, 3, 1), .prev_start, b)));
}
