const std = @import("std");
const http = std.http;
const heap = std.heap;

pub const Errors = error{ TagNotFound, NoUrl };

const Element = struct {
    tag: []const u8,
    index: u16,
    inner_html: []const u8,
    attributes: [50]Attribute,
    attribute_count: usize,

    pub fn print(self: Element) void {
        std.debug.print("element {}:\n", .{ self.index });
        std.debug.print("  tag: {s}\n", .{ self.tag });
        // std.debug.print("  inner_html: {s}\n", .{self.inner_html});

        std.debug.print("  attributes:\n", .{});
        for (self.attributes[0..self.attribute_count]) |a| {
            std.debug.print("    key: {s}, value: {s}\n", .{ a.key, a.value });
        }
    }
};
const Attribute = struct { key: []const u8, value: []const u8 };

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip();

    const url = args.next() orelse return Errors.NoUrl;
    const html = try getHtml(url, allocator);
    defer allocator.free(html);
    std.debug.print("getHtml: {s}\n", .{html});

    var t = try std.time.Timer.start();

    var elements = std.ArrayList(Element).init(allocator);
    defer elements.deinit();

    try getElements(html, &elements);
    // try getElementsWithAmounts(&elements);

    for (elements.items) |element| {
        element.print();
        // std.debug.print("[element]\ntag: {s}\nindex: {}\ninner_html: {s}\n", .{ element.tag, element.index, element.inner_html });
    }

    std.debug.print("elements.items.len: {}\nexecution time: {}\n", .{ elements.items.len, std.fmt.fmtDuration(t.read()) });
}

pub fn getHtml(url: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var c = http.Client{ .allocator = allocator };
    defer c.deinit();

    var body_container = std.ArrayList(u8).init(allocator);

    const fetch_options = http.Client.FetchOptions{ .location = http.Client.FetchOptions.Location{ .url = url }, .response_storage = .{ .dynamic = &body_container } };

    const res = try c.fetch(fetch_options);
    const body = try body_container.toOwnedSlice();

    if (res.status != .ok) std.log.err("getHtml failed: {s}\n", .{body});

    return body;
}

pub fn getElementsWithAmounts(elements: *std.ArrayList(Element)) !void {
    try removeElementsWithChildren(elements);

    var count: usize = 0;

    for (elements.items) |element| {
        if (std.mem.indexOf(u8, element.tag, "script") != null) continue;
        if (std.mem.indexOf(u8, element.inner_html, "$") == null) continue;
        if (!hasNumber(element.inner_html)) continue;

        elements.items[count] = element;
        count += 1;
    }

    try elements.resize(count);
}

pub fn hasNumber(slice: []const u8) bool {
    for (slice) |byte| {
        if (byte >= '0' and byte <= '9') return true;
    }

    return false;
}

// very basic check for elements with children
pub fn removeElementsWithChildren(elements: *std.ArrayList(Element)) !void {
    var count: usize = 0;

    for (elements.items) |element| {
        if (std.mem.indexOf(u8, element.inner_html, "</") != null) continue;
        if (std.mem.indexOf(u8, element.inner_html, "/>") != null) continue;

        elements.items[count] = element;
        count += 1;
    }

    try elements.resize(count);
}

pub fn getElements(html: []const u8, elements: *std.ArrayList(Element)) !void {
    var element_count: u16 = 0;

    for (0.., html) |i, char| {
        if (char != '<') continue;

        const full_tag = getFirstOpeningTag(html[i..]) orelse continue;
        const tag = getElementNameFromTag(full_tag);

        const open_tag_end_index = std.mem.indexOf(u8, html[i..], ">") orelse continue;
        const inner_start_index = i + open_tag_end_index + 1;

        const close_tag_index = try getCloseTagIndex(html[inner_start_index..], tag) orelse continue;
        const inner_end_index = close_tag_index + inner_start_index;

        const inner = html[inner_start_index..inner_end_index];
        if (inner.len == 0) continue;

        element_count += 1;

        var attributes: [50]Attribute = undefined;
        const attribute_count = fillElementAttributes(full_tag, &attributes);
        // const attributes = fillElementAttributes(full_tag);

        const element = Element{ .tag = tag, .index = element_count, .inner_html = inner, .attributes = attributes, .attribute_count = attribute_count };

        try elements.append(element);
    }
}

// todo: values should be trimmed
pub fn fillElementAttributes(start_tag: []const u8, attributes: *[50]Attribute) usize {
    if (std.mem.startsWith(u8, start_tag, "script")) return 0; // todo: handle script tags

    // std.debug.print("start_tag: {s}\n", .{start_tag});

    // var attributes: [50]Attribute = undefined;
    var attribute_count: usize = 0;
    var base_index: usize = 0;

    while (base_index < start_tag.len) {
        const start = start_tag[base_index..];

        const equal_index = std.mem.indexOf(u8, start, "=") orelse break;
        const key_start = std.mem.lastIndexOf(u8, start[0..equal_index], " ") orelse break;
        const key = start[key_start..equal_index];

        const value_surround_char = start[equal_index + 1];
        if (value_surround_char != '"' and value_surround_char != '\'') break;

        const value_start = equal_index + 2;
        const value_end_index = std.mem.indexOf(u8, start[value_start..], &[1]u8{value_surround_char}) orelse break;

        var value = start[value_start .. value_start + value_end_index];
        value = std.mem.trim(u8, value, &[2]u8{ ' ', '\n' });

        base_index += value_start + value_end_index + 1;
        if (value.len == 0 or key.len == 0) continue;

        attributes[attribute_count] = Attribute{ .key = key, .value = value };
        attribute_count += 1;
    }

    // for (attributes[0..attribute_count]) |a| {
    //     std.debug.print("{s}: {s}\n", .{ a.key, a.value });
    // }
    return attribute_count;

    // return attributes[0..attribute_count];
}

// returns what's between "<" and ">" including attributes
pub fn getFirstOpeningTag(html: []const u8) ?[]const u8 {
    const start_tag_end_index = std.mem.indexOf(u8, html, ">") orelse return null;
    const tag = html[1..start_tag_end_index];

    if (tag.len == 0 or tag[0] == '/' or tag[tag.len - 1] == '/' or tag[0] == '!' or tag[0] == '=') {
        return null;
    }

    return tag;
}

pub fn getElementNameFromTag(tag: []const u8) []const u8 {
    var name = tag;

    const space_index_opt = std.mem.indexOf(u8, tag, " ");
    if (space_index_opt != null) name = tag[0..space_index_opt.?];

    const break_index_opt = std.mem.indexOf(u8, tag, "\n");
    if (break_index_opt != null) name = tag[0..break_index_opt.?];

    return name;
}

// pub fn getFirstTag(html: []const u8) ?[]const u8 {
//     const start_tag_end_index = std.mem.indexOf(u8, html, ">") orelse return null;
//     var tag = html[1..start_tag_end_index];
//
//     if (tag.len == 0 or tag[0] == '/' or tag[tag.len - 1] == '/' or tag[0] == '!' or tag[0] == '=') {
//         return null;
//     }
//
//     const space_index_opt = std.mem.indexOf(u8, tag, " ");
//     if (space_index_opt != null) {
//         // getElementAttributes(tag);
//         tag = tag[0..space_index_opt.?];
//     }
//
//     const break_index_opt = std.mem.indexOf(u8, tag, "\n");
//     if (break_index_opt != null) tag = tag[0..break_index_opt.?];
//
//     return tag;
// }

pub fn getCloseTagIndex(html: []const u8, tag: []const u8) !?usize {
    var open_tag_count: usize = 1;
    var search_index: usize = 0;
    const open_tag_len = tag.len + 1; // "<" + tag
    const close_tag_len = tag.len + 3; // "</" + tag + ">"

    while (search_index < html.len) {
        const next_tag_index = std.mem.indexOf(u8, html[search_index..], "<") orelse break;
        search_index += next_tag_index;

        // check if opening tag
        if (std.mem.startsWith(u8, html[search_index + 1 ..], tag)) {
            if (html[search_index + 1 + tag.len] != '/') {
                open_tag_count += 1;
                search_index += open_tag_len;
                continue;
            }
        }

        // check if closing tag
        if (std.mem.startsWith(u8, html[search_index + 2 ..], tag) and html[search_index + 1] == '/') {
            open_tag_count -= 1;
            search_index += close_tag_len;

            if (open_tag_count == 0) {
                return search_index - close_tag_len;
            }
        }

        search_index += 1;
    }

    return null;
}
