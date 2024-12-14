const std = @import("std");
const zap = @import("zap");
const Dom = @import("html/dom.zig");
const Element = @import("html/element.zig");
const Tweet = @import("tweet.zig");

pub const Self = @This();

alloc: std.mem.Allocator = undefined,
ep: zap.Endpoint = undefined,

pub fn init(a: std.mem.Allocator, path: []const u8) Self {
    return .{
        .alloc = a,
        .ep = zap.Endpoint.init(.{ .path = path, .get = getTweet }),
    };
}

pub fn endpoint(self: *Self) *zap.Endpoint {
    return &self.ep;
}

fn getTweet(e: *zap.Endpoint, r: zap.Request) void {
    const self: *Self = @fieldParentPtr("ep", e);
    const path = r.path orelse return;

    if (path.len <= e.settings.path.len + 2 or path[e.settings.path.len] != '/') return;

    // works as at 13/12/24
    const part_one = "http://cdn.syndication.twimg.com/tweet-result?id=";
    const part_two = "&token=a";

    const id = path[e.settings.path.len + 1 ..];
    const url = std.mem.concat(self.alloc, u8, &[_][]const u8{ part_one, id, part_two }) catch return;
    defer self.alloc.free(url);

    var dom = Dom.init(self.alloc);
    defer dom.deinit();

    dom.getHtml(url) catch return;

    const x_tweet = std.json.parseFromSlice(std.json.Value, self.alloc, dom.html orelse return, .{}) catch |err| {
        std.debug.print("[getTweet] json.parseFromSlice: {}\n", .{err});
        return;
    };
    defer x_tweet.deinit();

    var parsed_tweet = parseTweet(self, x_tweet.value) catch return;
    defer parsed_tweet.deinit(self.alloc);

    const json = std.json.stringifyAlloc(self.alloc, parsed_tweet, .{}) catch |err| {
        std.debug.print("[getTweet] json.stringifyAlloc: {}\n", .{err});
        return;
    };
    defer self.alloc.free(json);

    r.sendJson(json) catch return;
}

// fn parseTweet(self: *Self, full_tweet: std.json.Value) !Tweet {
fn parseTweet(self: *Self, x_tweet: std.json.Value) !Tweet {
    const t = x_tweet.object;

    var tweet = Tweet{
        .userName = t.get("user").?.object.get("name").?.string,
        .displayName = t.get("user").?.object.get("screen_name").?.string,
        .id = t.get("id_str").?.string,
        .createDate = t.get("created_at").?.string,
        .text = t.get("text").?.string,
    };

    const media_arr = t.get("mediaDetails").?.array;
    // todo: handle multiple media
    if (media_arr.items.len > 0) {
        const url_https = media_arr.items[0].object.get("media_url_https").?.string;

        const http = url_https[0..4];
        const url = url_https[5..];

        const url_http = try std.mem.concat(self.alloc, u8, &[_][]const u8{ http, url });
        // defer self.alloc.free(url_http);

        tweet.media = try getMedia(self, url_http);
    }

    return tweet;
}

fn getMedia(self: *Self, media_url: []const u8) !?Tweet.Media {
    var dom = Dom.init(self.alloc);
    defer dom.deinit();

    dom.getHtml(media_url) catch |err| {
        std.debug.print("[getMedia] dom.getHtml: {}\n", .{err});
        return err;
    };

    const binary = dom.html orelse return null;
    const encoder = std.base64.standard.Encoder;
    const encoded = try self.alloc.alloc(u8, encoder.calcSize(binary.len));
    // defer self.alloc.free(encoded);

    _ = encoder.encode(encoded, binary);

    var i = media_url.len;
    while (i > 0) { // find last '.'
        i -= 1;
        if (media_url[i] == '.') break;
    }

    const file_type = media_url[i + 1 ..];

    return Tweet.Media{
        .url = media_url,
        .base64 = encoded,
        .file_type = file_type,
    };
}
