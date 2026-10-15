// Seek: native macOS floating search bar on top of libseek (Zig core, see include/seek.h).
//
// - Option+Space toggles a Spotlight-style panel that never steals focus from your app
// - Type to search; ↑/↓ (or Ctrl-P/N) to move, Return to open, Cmd+Return to reveal in Finder,
//   Cmd+C (with no text selected) to copy the path, Esc to clear, Esc again to close
// - Menu bar icon: index a folder, reindex now, launch at login, quit
//
// Built by `zig build app` with Apple's clang (ARC). One file on purpose: rebuilds take ~1 s.

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <PDFKit/PDFKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
#include <string.h>
#include "seek.h"

static const CGFloat kWidth = 800;
static const CGFloat kListWidth = 470;
static const CGFloat kFieldHeight = 62;
static const CGFloat kChipsHeight = 44;
static const CGFloat kFooterHeight = 32;
static const CGFloat kBodyMinHeight = 300; // keeps the detail pane from being cramped on short result lists
static const CGFloat kRowHeight = 46;
static const NSInteger kVisibleRows = 7;
enum { kMaxResults = 60 }; // a true constant: sizes a stack array inside a block
static const NSTimeInterval kReindexInterval = 15 * 60; // until the file watcher lands (M2)

static atomic_ulong gQueryGeneration;

// ------------------------------------------------------------------ result model

@interface SeekItem : NSObject
@property(copy) NSString *path;
@property(copy) NSString *name;
@property BOOL isDir;
@property uint64_t size;
@property NSDate *modified;
@end
@implementation SeekItem
@end

// ------------------------------------------------------------------ panel

@protocol SeekPanelKeys <NSObject>
- (BOOL)panelHandleKeyDown:(NSEvent *)event;
@end

@interface SeekPanel : NSPanel
@property(weak) id<SeekPanelKeys> keyHandler;
@end

@implementation SeekPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown && [self.keyHandler panelHandleKeyDown:event]) return;
    [super sendEvent:event];
}
@end

// ------------------------------------------------------------------ rows

@interface SeekRowView : NSTableRowView
@end

@implementation SeekRowView
// The search field keeps focus, so force the "active" selection look.
- (BOOL)isEmphasized { return YES; }
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (!self.selected) return;
    NSRect r = NSInsetRect(self.bounds, 8, 1);
    [[NSColor selectedContentBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8] fill];
}
@end

@interface SeekCell : NSTableCellView
@property(strong) NSTextField *title;
@property(strong) NSTextField *subtitle;
@property(strong) NSTextField *meta;
@property(copy) NSString *name;
@property(copy) NSArray<NSValue *> *highlights;
@end

@implementation SeekCell
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    NSImageView *icon = [NSImageView new];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.imageView = icon;

    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont systemFontOfSize:14];
    _title.lineBreakMode = NSLineBreakByTruncatingMiddle;

    _subtitle = [NSTextField labelWithString:@""];
    _subtitle.font = [NSFont systemFontOfSize:11];
    _subtitle.lineBreakMode = NSLineBreakByTruncatingHead;

    _meta = [NSTextField labelWithString:@""];
    _meta.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _meta.alignment = NSTextAlignmentRight;
    [_meta setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_meta setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView *v in @[ icon, _title, _subtitle, _meta ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
        [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:30],
        [icon.heightAnchor constraintEqualToConstant:30],
        [_title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [_title.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
        [_title.trailingAnchor constraintLessThanOrEqualToAnchor:_meta.leadingAnchor constant:-10],
        [_subtitle.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
        [_subtitle.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:1],
        [_subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:_meta.leadingAnchor constant:-10],
        [_meta.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
        [_meta.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

- (void)setBackgroundStyle:(NSBackgroundStyle)style {
    [super setBackgroundStyle:style];
    [self refreshColors];
}

- (void)refreshColors {
    BOOL selected = self.backgroundStyle == NSBackgroundStyleEmphasized;
    NSColor *primary = selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
    NSColor *secondary = selected ? [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.8]
                                  : NSColor.secondaryLabelColor;
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
        initWithString:self.name ?: @""
            attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:14],
                         NSForegroundColorAttributeName : primary}];
    for (NSValue *v in self.highlights) {
        NSRange r = v.rangeValue;
        if (NSMaxRange(r) <= s.length)
            [s addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:14 weight:NSFontWeightBold] range:r];
    }
    self.title.attributedStringValue = s;
    self.subtitle.textColor = secondary;
    self.meta.textColor = secondary;
}
@end

// ------------------------------------------------------------------ chips, cards, detail pane

static NSTextField *MakeLabel(NSString *s, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

@interface SeekFlipView : NSView
@end
@implementation SeekFlipView
- (BOOL)isFlipped { return YES; }
@end

// A pill-shaped chip. With options it is a filter popup: picking anything but the first option
// turns it on (accent fill) and shows "Title: Choice". Without options it is a plain label.
@interface SeekChip : NSView
@property(copy) NSArray<NSString *> *options;
@property(nonatomic) NSInteger selected;
@property(copy) void (^onChange)(void);
@property(copy) void (^onClick)(void); // for chips without options
@property(nonatomic) BOOL disabled;
@property BOOL menuOpen; // read by the panel so the popup menu doesn't count as losing focus
- (instancetype)initWithTitle:(NSString *)title caret:(BOOL)caret;
@end

@implementation SeekChip {
    NSString *_title;
    BOOL _caret;
}
- (instancetype)initWithTitle:(NSString *)title caret:(BOOL)caret {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 10, 26)])) return nil;
    _title = [title copy];
    _caret = caret;
    [self refit];
    return self;
}
- (BOOL)active { return _selected > 0; }
- (NSString *)shownTitle {
    return self.active ? [NSString stringWithFormat:@"%@: %@", _title, _options[(NSUInteger)_selected]] : _title;
}
- (NSDictionary *)attrs {
    return @{NSFontAttributeName : [NSFont systemFontOfSize:12.5 weight:self.active ? NSFontWeightMedium : NSFontWeightRegular]};
}
- (void)refit {
    CGFloat w = ceil([[self shownTitle] sizeWithAttributes:[self attrs]].width) + 22 + (_caret ? 14 : 0);
    NSRect f = self.frame;
    f.size.width = w;
    self.frame = f;
    self.needsDisplay = YES;
}
- (void)setSelected:(NSInteger)selected {
    _selected = selected;
    [self refit];
}
- (void)setDisabled:(BOOL)disabled {
    _disabled = disabled;
    self.alphaValue = disabled ? 0.45 : 1;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent *)event {
    if (_disabled) return;
    if (_options.count == 0) {
        if (_onClick) _onClick();
        return;
    }
    NSMenu *menu = [NSMenu new];
    for (NSUInteger i = 0; i < _options.count; i++) {
        NSMenuItem *it = [menu addItemWithTitle:_options[i] action:@selector(pick:) keyEquivalent:@""];
        it.target = self;
        it.tag = (NSInteger)i;
        it.state = (NSInteger)i == _selected ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _menuOpen = YES;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:self];
    _menuOpen = NO;
}
- (void)pick:(NSMenuItem *)item {
    if (item.tag == _selected) return;
    self.selected = item.tag;
    if (_onChange) _onChange();
}
- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:13 yRadius:13];
    NSColor *fg = NSColor.labelColor;
    if (self.active) {
        [NSColor.controlAccentColor setFill];
        [p fill];
        fg = NSColor.alternateSelectedControlTextColor;
    } else {
        [[NSColor.labelColor colorWithAlphaComponent:0.05] setFill];
        [p fill];
        [[NSColor.labelColor colorWithAlphaComponent:0.16] setStroke];
        p.lineWidth = 1;
        [p stroke];
    }
    NSMutableDictionary *attrs = [[self attrs] mutableCopy];
    attrs[NSForegroundColorAttributeName] = fg;
    NSString *t = [self shownTitle];
    NSSize ts = [t sizeWithAttributes:attrs];
    [t drawAtPoint:NSMakePoint(11, (self.bounds.size.height - ts.height) / 2) withAttributes:attrs];
    if (_caret) {
        NSDictionary *ca = @{NSFontAttributeName : [NSFont systemFontOfSize:8],
                             NSForegroundColorAttributeName : self.active ? fg : NSColor.secondaryLabelColor};
        [@"▾" drawAtPoint:NSMakePoint(self.bounds.size.width - 18, (self.bounds.size.height - 10) / 2) withAttributes:ca];
    }
}
@end

// Rounded, bordered container used by the detail snippets and the settings lists.
@interface SeekCard : SeekFlipView
@end
@implementation SeekCard
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [NSColor.controlBackgroundColor setFill];
    [p fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setStroke];
    [p stroke];
}
@end

// Right-hand pane of the search bar: icon, name, location, the few facts that matter for this kind of
// file, a duplicates line and the actions. Rows are filled in three steps (basics now, type-specific
// facts and duplicates when their background lookups finish).
@interface SeekDetail : SeekFlipView
@property(strong) NSImageView *icon;
@property(strong) NSTextField *name;
@property(strong) NSTextField *path;
@property(strong) NSButton *openButton;
@property(strong) NSButton *revealButton;
@property(strong) NSButton *pathButton;
- (void)showItem:(SeekItem *)item icon:(NSImage *)icon;
- (void)setExtras:(NSArray<NSArray<NSString *> *> *)extras; // [[key, value], ...]
- (void)setDuplicates:(NSString *)text found:(BOOL)found;   // nil hides the row
@end

@implementation SeekDetail {
    NSArray<NSTextField *> *_keys, *_vals;
    NSArray<NSArray<NSString *> *> *_basics, *_extras;
    NSString *_dupText;
    BOOL _dupFound;
}
enum { kDetailRows = 8 };

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _icon = [NSImageView new];
    _icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    _name = MakeLabel(@"", 15, NSFontWeightSemibold, NSColor.labelColor);
    _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _path = MakeLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _path.lineBreakMode = NSLineBreakByTruncatingHead;

    NSMutableArray *keys = [NSMutableArray array], *vals = [NSMutableArray array];
    for (int i = 0; i < kDetailRows; i++) {
        NSTextField *k = MakeLabel(@"", 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        NSTextField *v = MakeLabel(@"", 12, NSFontWeightRegular, NSColor.labelColor);
        [self addSubview:k];
        [self addSubview:v];
        [keys addObject:k];
        [vals addObject:v];
    }
    _keys = keys;
    _vals = vals;

    _openButton = [NSButton buttonWithTitle:@"Open" target:nil action:nil];
    _openButton.bezelColor = NSColor.controlAccentColor;
    _revealButton = [NSButton buttonWithTitle:@"Reveal" target:nil action:nil];
    _pathButton = [NSButton buttonWithTitle:@"Copy path" target:nil action:nil];
    for (NSView *v in @[ _icon, _name, _path, _openButton, _revealButton, _pathButton ]) [self addSubview:v];
    for (NSButton *b in @[ _openButton, _revealButton, _pathButton ]) {
        b.refusesFirstResponder = YES; // typing stays in the search field
        b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:12];
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, pad = 18;
    _icon.frame = NSMakeRect(pad, 16, 40, 40);
    _name.frame = NSMakeRect(pad + 50, 17, w - pad * 2 - 50, 20);
    _path.frame = NSMakeRect(pad + 50, 38, w - pad * 2 - 50, 16);
    CGFloat gap = 8, bw = (w - pad * 2 - gap * 2) / 3, by = h - 18 - 26;
    _openButton.frame = NSMakeRect(pad, by, bw, 26);
    _revealButton.frame = NSMakeRect(pad + bw + gap, by, bw, 26);
    _pathButton.frame = NSMakeRect(pad + (bw + gap) * 2, by, bw, 26);
    [self placeRows];
}

// Basics, then type-specific facts, then duplicates; unused slots are hidden.
- (void)placeRows {
    NSMutableArray *rows = [NSMutableArray arrayWithArray:_basics ?: @[]];
    [rows addObjectsFromArray:_extras ?: @[]];
    if (_dupText) [rows addObject:@[ @"Duplicates", _dupText, _dupFound ? @"warn" : @"" ]];
    CGFloat w = self.bounds.size.width, pad = 18, y = 78;
    for (int i = 0; i < kDetailRows; i++) {
        BOOL on = i < (int)rows.count;
        _keys[i].hidden = _vals[i].hidden = !on;
        if (!on) continue;
        NSArray *r = rows[i];
        _keys[i].stringValue = r[0];
        _vals[i].stringValue = r[1];
        _vals[i].textColor = r.count > 2 && [r[2] isEqualToString:@"warn"] ? NSColor.systemOrangeColor : NSColor.labelColor;
        _vals[i].font = [NSFont systemFontOfSize:12 weight:r.count > 2 && [r[2] length] ? NSFontWeightSemibold : NSFontWeightRegular];
        _keys[i].frame = NSMakeRect(pad, y, 70, 16);
        _vals[i].frame = NSMakeRect(pad + 78, y, w - pad * 2 - 78, 16);
        y += 24;
    }
}

- (void)showItem:(SeekItem *)it icon:(NSImage *)icon {
    static NSDateFormatter *df;
    if (!df) {
        df = [NSDateFormatter new];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterShortStyle;
    }
    NSDictionary *rv = [[NSURL fileURLWithPath:it.path] resourceValuesForKeys:@[ NSURLLocalizedTypeDescriptionKey ] error:nil];
    _icon.image = icon;
    _name.stringValue = it.name;
    _path.stringValue = it.path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
    NSString *kind = rv[NSURLLocalizedTypeDescriptionKey] ?: (it.isDir ? @"Folder" : @"Document");
    NSMutableArray *basics = [NSMutableArray arrayWithObject:@[ @"Kind", kind ]];
    if (!it.isDir)
        [basics addObject:@[ @"Size", [NSByteCountFormatter stringFromByteCount:(long long)it.size
                                                                     countStyle:NSByteCountFormatterCountStyleFile] ]];
    [basics addObject:@[ @"Modified", [df stringFromDate:it.modified] ]];
    _basics = basics;
    _extras = nil;
    _dupText = nil;
    [self placeRows];
}

- (void)setExtras:(NSArray<NSArray<NSString *> *> *)extras {
    _extras = extras;
    [self placeRows];
}

- (void)setDuplicates:(NSString *)text found:(BOOL)found {
    _dupText = text;
    _dupFound = found;
    [self placeRows];
}
@end

// ------------------------------------------------------------------ file type icons

static NSColor *RGB(int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0
                                blue:(hex & 255) / 255.0 alpha:1];
}

// One colour per family of file types, in the spirit of the extension badges in the design.
static NSColor *BadgeColor(NSString *ext) {
    static NSDictionary<NSString *, NSColor *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        void (^add)(int, NSString *) = ^(int hex, NSString *exts) {
            for (NSString *e in [exts componentsSeparatedByString:@" "]) m[e] = RGB(hex);
        };
        add(0xD9453D, @"pdf");
        add(0x2F6FD0, @"doc docx pages rtf odt");
        add(0x2F9E5B, @"xls xlsx numbers csv ods");
        add(0xE07B2E, @"ppt pptx key");
        add(0x7A7F87, @"txt md log");
        add(0x8B5CF6, @"png jpg jpeg gif heic heif webp tif tiff bmp svg raw cr2 nef dng psd");
        add(0xE0529C, @"mp3 m4a aac wav flac aiff ogg opus");
        add(0x4F5BD5, @"mp4 mov m4v mkv avi webm");
        add(0x14A3A8, @"zig c h m mm cpp hpp rs go py js ts tsx jsx swift java kt rb sh json yaml yml toml html css");
        add(0x9A6B3F, @"zip tar gz tgz bz2 xz 7z rar dmg iso");
        map = m;
    });
    return map[ext] ?: RGB(0x8E8E93);
}

static NSImage *BadgeIcon(NSString *ext) {
    NSString *label = ext.length == 0 ? @"FILE" : ext.uppercaseString;
    if (label.length > 4) label = [label substringToIndex:4];
    NSColor *color = BadgeColor(ext);
    return [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 4, 4) xRadius:14 yRadius:14];
        [color setFill];
        [p fill];
        CGFloat size = label.length <= 3 ? 20 : 15;
        NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:size weight:NSFontWeightBold],
                                NSForegroundColorAttributeName : NSColor.whiteColor};
        NSSize ts = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(NSMidX(r) - ts.width / 2, NSMidY(r) - ts.height / 2) withAttributes:attrs];
        return YES;
    }];
}

static BOOL HasThumbnail(NSString *ext) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:[@"png jpg jpeg gif heic heif webp tif tiff bmp" componentsSeparatedByString:@" "]];
    });
    return [set containsObject:ext];
}

// ------------------------------------------------------------------ type-specific facts & duplicates

static NSString *FormatCount(uint64_t n);

static NSString *FormatDuration(double s) {
    if (!isfinite(s) || s <= 0) return nil;
    long t = lround(s);
    return t >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60]
                     : [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

static NSString *MetaString(AVAsset *asset, AVMetadataKey key) {
    NSArray *items = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata withKey:key keySpace:AVMetadataKeySpaceCommon];
    NSString *v = items.firstObject ? [items.firstObject stringValue] : nil;
    return v.length ? v : nil;
}

// The few facts worth showing for this kind of file. Runs off the main thread; may touch the disk.
static NSArray<NSArray<NSString *> *> *ExtraDetails(SeekItem *it) {
    NSMutableArray *rows = [NSMutableArray array];
    NSString *ext = it.path.pathExtension.lowercaseString;
    NSURL *url = [NSURL fileURLWithPath:it.path];
    void (^add)(NSString *, NSString *) = ^(NSString *k, NSString *v) {
        if (v.length) [rows addObject:@[ k, v ]];
    };
    static NSSet *images, *av, *video, *textual;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        images = [NSSet setWithArray:[@"png jpg jpeg gif heic heif webp tif tiff bmp cr2 nef dng" componentsSeparatedByString:@" "]];
        video = [NSSet setWithArray:[@"mp4 mov m4v mkv avi webm" componentsSeparatedByString:@" "]];
        av = [NSSet setWithArray:[@"mp3 m4a aac wav flac aiff mp4 mov m4v" componentsSeparatedByString:@" "]];
        textual = [NSSet setWithArray:[@"txt md csv json yaml yml toml html css zig c h m mm cpp hpp rs go py js ts tsx jsx swift java kt rb sh log"
                                           componentsSeparatedByString:@" "]];
    });
    if ([ext isEqualToString:@"app"]) {
        NSBundle *b = [NSBundle bundleWithURL:url];
        add(@"Version", b.infoDictionary[@"CFBundleShortVersionString"]);
    } else if (it.isDir) {
        NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:it.path error:nil];
        if (items) add(@"Items", [NSString stringWithFormat:@"%lu", (unsigned long)items.count]);
    } else if ([images containsObject:ext]) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        NSDictionary *props = src ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL)) : nil;
        if (src) CFRelease(src);
        NSNumber *w = props[(__bridge NSString *)kCGImagePropertyPixelWidth];
        NSNumber *h = props[(__bridge NSString *)kCGImagePropertyPixelHeight];
        if (w && h) add(@"Dimensions", [NSString stringWithFormat:@"%@ × %@ px", w, h]);
        NSDictionary *tiff = props[(__bridge NSString *)kCGImagePropertyTIFFDictionary];
        NSString *make = tiff[(__bridge NSString *)kCGImagePropertyTIFFMake], *model = tiff[(__bridge NSString *)kCGImagePropertyTIFFModel];
        if (model) add(@"Camera", [model hasPrefix:make ?: @"\0"] ? model : [NSString stringWithFormat:@"%@ %@", make ?: @"", model]);
        NSDictionary *exif = props[(__bridge NSString *)kCGImagePropertyExifDictionary];
        add(@"Taken", exif[(__bridge NSString *)kCGImagePropertyExifDateTimeOriginal]);
    } else if ([ext isEqualToString:@"pdf"]) {
        PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
        if (doc) {
            add(@"Pages", [NSString stringWithFormat:@"%lu", (unsigned long)doc.pageCount]);
            add(@"Title", doc.documentAttributes[PDFDocumentTitleAttribute]);
            add(@"Author", doc.documentAttributes[PDFDocumentAuthorAttribute]);
        }
    } else if ([av containsObject:ext]) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        add(@"Duration", FormatDuration(CMTimeGetSeconds(asset.duration)));
        if ([video containsObject:ext]) {
            AVAssetTrack *t = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (t) add(@"Dimensions", [NSString stringWithFormat:@"%.0f × %.0f px", t.naturalSize.width, t.naturalSize.height]);
        } else {
            add(@"Artist", MetaString(asset, AVMetadataCommonKeyArtist));
            add(@"Album", MetaString(asset, AVMetadataCommonKeyAlbumName));
        }
    } else if ([textual containsObject:ext] && it.size > 0 && it.size < 4 * 1024 * 1024) {
        NSData *d = [NSData dataWithContentsOfURL:url];
        const char *b = d.bytes;
        NSUInteger lines = d.length ? 1 : 0;
        for (NSUInteger i = 0; i < d.length; i++) if (b[i] == '\n') lines++;
        if (d.length && b[d.length - 1] == '\n') lines--;
        add(@"Lines", FormatCount(lines));
    }
    return rows;
}

// SHA-256 of the first `limit` bytes (0 = whole file); nil if unreadable.
static NSData *FileDigest(NSString *path, size_t limit) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    static const size_t kChunk = 1 << 20;
    unsigned char *buf = malloc(kChunk);
    size_t left = limit ?: SIZE_MAX;
    while (left > 0) {
        size_t want = MIN(kChunk, left);
        size_t n = fread(buf, 1, want, f);
        if (n > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
        left -= n;
        if (n < want) break; // end of file or a read error: stop either way
    }
    free(buf);
    fclose(f);
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(out, &ctx);
    return [NSData dataWithBytes:out length:sizeof out];
}

// ------------------------------------------------------------------ helpers

static NSImage *RoundedMask(CGFloat radius) {
    CGFloat d = radius * 2 + 1;
    NSImage *img = [NSImage imageWithSize:NSMakeSize(d, d) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    img.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    img.resizingMode = NSImageResizingModeStretch;
    return img;
}

// Bold ranges for each query word found in the name; falls back to matching letters in order.
static NSArray<NSValue *> *HighlightRanges(NSString *name, NSString *query) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *words = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (NSString *w in words) {
        if (w.length == 0) continue;
        NSRange r = [name rangeOfString:w options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) {
            [out addObject:[NSValue valueWithRange:r]];
            continue;
        }
        NSMutableArray *letters = [NSMutableArray array];
        NSUInteger at = 0;
        for (NSUInteger i = 0; i < w.length && at < name.length; i++) {
            NSRange c = [name rangeOfString:[w substringWithRange:NSMakeRange(i, 1)]
                                    options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(at, name.length - at)];
            if (c.location == NSNotFound) { [letters removeAllObjects]; break; }
            [letters addObject:[NSValue valueWithRange:c]];
            at = NSMaxRange(c);
        }
        if (letters.count == w.length) [out addObjectsFromArray:letters];
    }
    return out;
}

static NSString *FormatCount(uint64_t n) {
    static NSNumberFormatter *f;
    if (!f) {
        f = [NSNumberFormatter new];
        f.numberStyle = NSNumberFormatterDecimalStyle;
    }
    return [f stringFromNumber:@(n)];
}

// ------------------------------------------------------------------ settings & duplicates windows
// Static layouts for now: nothing in them is wired up yet.

static NSWindow *MakeWindow(NSString *title, CGFloat w, CGFloat h) {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskMiniaturizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = title;
    win.releasedWhenClosed = NO;
    [win center];
    return win;
}

static NSImageView *SymbolView(NSString *name, CGFloat size, NSColor *tint) {
    NSImage *img = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size
                                                                                     weight:NSFontWeightRegular]];
    NSImageView *v = [NSImageView imageViewWithImage:img];
    v.contentTintColor = tint;
    return v;
}

static NSButton *PushButton(NSString *title, NSRect frame, BOOL prominent) {
    NSButton *b = [NSButton buttonWithTitle:title target:nil action:nil];
    b.frame = frame;
    if (prominent) b.bezelColor = NSColor.controlAccentColor;
    return b;
}

// ------------------------------------------------------------------ settings

@protocol SeekSettingsHost <NSObject>
- (seek_index *)settingsIndex;
- (NSString *)settingsStatusLine;
- (BOOL)settingsIsIndexing;
- (BOOL)settingsLoginEnabled;
- (void)toggleLogin;
- (void)chooseFolder;
- (void)reindexAll;
- (void)removeFolder:(NSString *)path;
- (void)addExclude:(NSString *)pattern;
- (void)removeExclude:(NSString *)pattern;
@end

static void CollectString(void *ctx, const char *s, uint64_t n) {
    [(__bridge NSMutableArray *)ctx addObject:@[ @(s), @(n) ]];
}

// A selectable row in the settings sidebar.
@interface SeekSideRow : SeekFlipView
@property(copy) void (^onSelect)(void);
@property(nonatomic) BOOL selected;
@property(strong) NSImageView *symbol;
@property(strong) NSTextField *label;
@end
@implementation SeekSideRow
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)sym frame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 7;
    _symbol = SymbolView(sym, 13, NSColor.labelColor);
    _symbol.frame = NSMakeRect(8, 4, 18, 18);
    _label = MakeLabel(title, 13, NSFontWeightRegular, NSColor.labelColor);
    _label.frame = NSMakeRect(32, 4, f.size.width - 36, 18);
    [self addSubview:_symbol];
    [self addSubview:_label];
    return self;
}
- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.layer.backgroundColor = selected ? NSColor.controlAccentColor.CGColor : NSColor.clearColor.CGColor;
    NSColor *fg = selected ? NSColor.whiteColor : NSColor.labelColor;
    _symbol.contentTintColor = fg;
    _label.textColor = fg;
    _label.font = [NSFont systemFontOfSize:13 weight:selected ? NSFontWeightMedium : NSFontWeightRegular];
}
- (void)mouseDown:(NSEvent *)e { if (_onSelect) _onSelect(); }
@end

@interface SeekSettings : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property(readonly) NSWindow *window;
- (instancetype)initWithHost:(id<SeekSettingsHost>)host;
- (void)show;
- (void)refresh;       // re-reads folders and exclusions (in the background)
- (void)statusChanged; // indexing progress
@end

@implementation SeekSettings {
    NSWindow *_win;
    __weak id<SeekSettingsHost> _host;
    NSArray<SeekFlipView *> *_panes;
    NSArray<SeekSideRow *> *_rows;
    NSTableView *_foldersTable, *_excludesTable;
    NSArray<NSArray *> *_roots, *_excludes, *_defaults;
    NSTextField *_foldersStatus, *_indexStatus, *_dbInfo, *_excludeField;
    NSSwitch *_loginSwitch;
    NSButton *_removeFolder, *_removeExclude;
}

static const CGFloat kSettingsW = 760, kSettingsH = 540, kSide = 180, kPad = 24;

- (instancetype)initWithHost:(id<SeekSettingsHost>)host {
    if (!(self = [super init])) return nil;
    _host = host;
    _roots = @[];
    _excludes = @[];
    NSMutableArray *defs = [NSMutableArray array];
    seek_list_default_excludes(CollectString, (__bridge void *)defs);
    _defaults = defs;
    [self build];
    [self refresh];
    return self;
}

- (NSWindow *)window { return _win; }
- (void)show {
    [self refresh];
    [self select:0 orKeep:YES];
    [_win makeKeyAndOrderFront:nil];
}

- (void)select:(NSInteger)i orKeep:(BOOL)keep {
    if (keep) {
        for (NSUInteger k = 0; k < _rows.count; k++) if (_rows[k].selected) return;
    }
    for (NSUInteger k = 0; k < _rows.count; k++) {
        _rows[k].selected = (NSInteger)k == i;
        _panes[k].hidden = (NSInteger)k != i;
    }
}

- (NSTableView *)makeTableWithColumns:(NSArray<NSArray *> *)cols { // [[id, title, width], ...]
    NSTableView *t = [NSTableView new];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1];
        col.width = [c[2] doubleValue];
        if ([c[2] doubleValue] == 0) col.resizingMask = NSTableColumnAutoresizingMask;
        [t addTableColumn:col];
    }
    t.rowHeight = 26;
    t.usesAlternatingRowBackgroundColors = YES;
    t.dataSource = self;
    t.delegate = self;
    t.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    return t;
}

- (NSScrollView *)scrollFor:(NSTableView *)t frame:(NSRect)f {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:f];
    sv.documentView = t;
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    return sv;
}

- (NSTextField *)titleFor:(SeekFlipView *)pane title:(NSString *)t sub:(NSString *)sub {
    NSTextField *title = MakeLabel(t, 20, NSFontWeightSemibold, NSColor.labelColor);
    title.frame = NSMakeRect(kPad, 22, kSettingsW - kSide - kPad * 2, 26);
    NSTextField *s = MakeLabel(sub, 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    s.frame = NSMakeRect(kPad, 50, kSettingsW - kSide - kPad * 2, 16);
    [pane addSubview:title];
    [pane addSubview:s];
    return s;
}

- (NSButton *)button:(NSString *)title action:(SEL)sel frame:(NSRect)f {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.frame = f;
    return b;
}

- (void)build {
    _win = MakeWindow(@"Seek Settings", kSettingsW, kSettingsH);
    CGFloat pw = kSettingsW - kSide, cw = pw - kPad * 2;

    // sidebar
    NSVisualEffectView *sidebar = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kSide, kSettingsH)];
    sidebar.material = NSVisualEffectMaterialSidebar;
    sidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    SeekFlipView *list = [[SeekFlipView alloc] initWithFrame:sidebar.bounds];
    [sidebar addSubview:list];
    NSArray *tabs = @[ @[ @"General", @"gearshape" ], @[ @"Folders", @"folder" ],
                       @[ @"Exclusions", @"nosign" ], @[ @"Index & Privacy", @"lock" ] ];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < tabs.count; i++) {
        SeekSideRow *row = [[SeekSideRow alloc] initWithTitle:tabs[i][0] symbol:tabs[i][1]
                                                        frame:NSMakeRect(10, 14 + i * 30, kSide - 20, 26)];
        __weak SeekSettings *me = self;
        NSInteger idx = (NSInteger)i;
        row.onSelect = ^{ [me select:idx orKeep:NO]; };
        [list addSubview:row];
        [rows addObject:row];
    }
    _rows = rows;

    NSMutableArray *panes = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        SeekFlipView *p = [[SeekFlipView alloc] initWithFrame:NSMakeRect(kSide, 0, pw, kSettingsH)];
        [panes addObject:p];
    }
    _panes = panes;

    // ---- General
    SeekFlipView *g = panes[0];
    [self titleFor:g title:@"General" sub:@"How Seek starts and how you reach it."];
    SeekCard *gc = [[SeekCard alloc] initWithFrame:NSMakeRect(kPad, 82, cw, 2 * 46)];
    NSTextField *l1 = MakeLabel(@"Launch at login", 13, NSFontWeightRegular, NSColor.labelColor);
    l1.frame = NSMakeRect(12, 6, cw - 80, 18);
    NSTextField *h1 = MakeLabel(@"Seek stays in the menu bar, ready for the hotkey", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    h1.frame = NSMakeRect(12, 24, cw - 80, 15);
    _loginSwitch = [NSSwitch new];
    _loginSwitch.controlSize = NSControlSizeSmall;
    _loginSwitch.target = self;
    _loginSwitch.action = @selector(loginToggled:);
    [_loginSwitch sizeToFit];
    _loginSwitch.frame = NSMakeRect(cw - 12 - _loginSwitch.frame.size.width, (46 - _loginSwitch.frame.size.height) / 2, _loginSwitch.frame.size.width, _loginSwitch.frame.size.height);
    NSBox *gsep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 45, cw, 1)];
    gsep.boxType = NSBoxSeparator;
    NSTextField *l2 = MakeLabel(@"Global hotkey", 13, NSFontWeightRegular, NSColor.labelColor);
    l2.frame = NSMakeRect(12, 46 + 6, 200, 18);
    NSTextField *h2 = MakeLabel(@"Shows and hides the search bar from any app", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    h2.frame = NSMakeRect(12, 46 + 24, cw - 80, 15);
    SeekChip *hk = [[SeekChip alloc] initWithTitle:@"⌥ Space" caret:NO];
    hk.frame = NSMakeRect(cw - 12 - hk.frame.size.width, 46 + 33 - 13, hk.frame.size.width, 26);
    for (NSView *v in @[ l1, h1, _loginSwitch, gsep, l2, h2, hk ]) [gc addSubview:v];
    [g addSubview:gc];

    // ---- Folders
    SeekFlipView *f = panes[1];
    [self titleFor:f title:@"Folders" sub:@"Seek only indexes what you add here. Everything stays on this Mac."];
    _foldersTable = [self makeTableWithColumns:@[ @[ @"path", @"Folder", @0 ], @[ @"count", @"Items", @90 ], @[ @"state", @"Status", @80 ] ]];
    [f addSubview:[self scrollFor:_foldersTable frame:NSMakeRect(kPad, 82, cw, 280)]];
    [f addSubview:[self button:@"+" action:@selector(addFolder) frame:NSMakeRect(kPad, 372, 30, 26)]];
    _removeFolder = [self button:@"−" action:@selector(removeSelectedFolder) frame:NSMakeRect(kPad + 34, 372, 30, 26)];
    [f addSubview:_removeFolder];
    [f addSubview:[self button:@"Reindex Now" action:@selector(reindex) frame:NSMakeRect(kPad + cw - 110, 372, 110, 26)]];
    _foldersStatus = MakeLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _foldersStatus.frame = NSMakeRect(kPad, 408, cw, 16);
    [f addSubview:_foldersStatus];

    // ---- Exclusions
    SeekFlipView *x = panes[2];
    [self titleFor:x title:@"Exclusions" sub:@"Names, patterns or folders Seek should never index. Applied on the next scan."];
    _excludeField = [NSTextField new];
    _excludeField.placeholderString = @"Name or pattern, e.g. *.log or build";
    _excludeField.frame = NSMakeRect(kPad, 82, cw - 190, 24);
    _excludeField.delegate = self;
    [x addSubview:_excludeField];
    [x addSubview:[self button:@"Add" action:@selector(addPattern) frame:NSMakeRect(kPad + cw - 182, 81, 60, 26)]];
    [x addSubview:[self button:@"Add Folder…" action:@selector(addExcludedFolder) frame:NSMakeRect(kPad + cw - 116, 81, 116, 26)]];
    _excludesTable = [self makeTableWithColumns:@[ @[ @"pattern", @"Excluded", @0 ] ]];
    [x addSubview:[self scrollFor:_excludesTable frame:NSMakeRect(kPad, 118, cw, 170)]];
    _removeExclude = [self button:@"−" action:@selector(removeSelectedExclude) frame:NSMakeRect(kPad, 296, 30, 26)];
    [x addSubview:_removeExclude];
    NSTextField *always = MakeLabel(@"Always skipped", 13, NSFontWeightSemibold, NSColor.labelColor);
    always.frame = NSMakeRect(kPad, 340, cw, 18);
    [x addSubview:always];
    NSMutableArray *names = [NSMutableArray array];
    for (NSArray *d in _defaults) [names addObject:d[0]];
    NSTextField *list2 = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:@"%@, and ~/Library inside your home folder. App bundles are listed but not searched inside.",
                                   [names componentsJoinedByString:@", "]]];
    list2.font = [NSFont systemFontOfSize:11];
    list2.textColor = NSColor.secondaryLabelColor;
    list2.frame = NSMakeRect(kPad, 362, cw, 80);
    [x addSubview:list2];

    // ---- Index & Privacy
    SeekFlipView *ix = panes[3];
    [self titleFor:ix title:@"Index & Privacy" sub:@"Where Seek keeps its data."];
    SeekCard *ic = [[SeekCard alloc] initWithFrame:NSMakeRect(kPad, 82, cw, 110)];
    _indexStatus = MakeLabel(@"", 13, NSFontWeightRegular, NSColor.labelColor);
    _indexStatus.frame = NSMakeRect(14, 14, cw - 28, 18);
    _dbInfo = MakeLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _dbInfo.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _dbInfo.frame = NSMakeRect(14, 38, cw - 28, 16);
    [ic addSubview:_indexStatus];
    [ic addSubview:_dbInfo];
    [ic addSubview:[self button:@"Reveal in Finder" action:@selector(revealDB) frame:NSMakeRect(14, 68, 130, 28)]];
    [ic addSubview:[self button:@"Rebuild Index" action:@selector(reindex) frame:NSMakeRect(152, 68, 120, 28)]];
    [ix addSubview:ic];
    NSTextField *priv = [NSTextField wrappingLabelWithString:
        @"Seek makes no network connections. File names, paths and metadata are read from your disk and stored only in the database above. Nothing is sent anywhere."];
    priv.font = [NSFont systemFontOfSize:12];
    priv.textColor = NSColor.secondaryLabelColor;
    priv.frame = NSMakeRect(kPad, 210, cw, 50);
    [ix addSubview:priv];

    NSView *root = _win.contentView;
    [root addSubview:sidebar];
    for (SeekFlipView *p in panes) [root addSubview:p];
    [self select:0 orKeep:NO];
}

// ---- data

- (void)refresh {
    id<SeekSettingsHost> host = _host;
    seek_index *idx = host.settingsIndex;
    _loginSwitch.state = host.settingsLoginEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self statusChanged];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *roots = [NSMutableArray array], *ex = [NSMutableArray array];
        seek_list_roots(idx, CollectString, (__bridge void *)roots); // may wait for a running scan
        seek_list_excludes(idx, CollectString, (__bridge void *)ex);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_roots = roots;
            self->_excludes = ex;
            [self->_foldersTable reloadData];
            [self->_excludesTable reloadData];
            [self statusChanged];
        });
    });
}

- (NSString *)dbPath {
    const char *env = getenv("SEEK_DB");
    return env ? @(env) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Seek/seek.db"];
}

- (void)statusChanged {
    id<SeekSettingsHost> host = _host;
    NSString *line = host.settingsStatusLine ?: @"";
    _foldersStatus.stringValue = _roots.count == 0 ? @"No folders yet. Click + to add one." : line;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:self.dbPath error:nil];
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)[attrs fileSize] countStyle:NSByteCountFormatterCountStyleFile];
    _indexStatus.stringValue = host.settingsIsIndexing ? line : [NSString stringWithFormat:@"%@ · up to date", line];
    _dbInfo.stringValue = [NSString stringWithFormat:@"%@ · %@", [self.dbPath stringByAbbreviatingWithTildeInPath], size];
    [_foldersTable reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)(t == _foldersTable ? _roots.count : _excludes.count);
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSString *text = @"";
    NSColor *color = NSColor.labelColor;
    NSTextAlignment align = NSTextAlignmentLeft;
    if (t == _foldersTable) {
        NSArray *r = _roots[(NSUInteger)row];
        if ([col.identifier isEqualToString:@"path"]) {
            text = [r[0] stringByAbbreviatingWithTildeInPath];
        } else if ([col.identifier isEqualToString:@"count"]) {
            text = FormatCount([r[1] unsignedLongLongValue]);
            color = NSColor.secondaryLabelColor;
            align = NSTextAlignmentRight;
        } else {
            BOOL there = [NSFileManager.defaultManager fileExistsAtPath:r[0]];
            BOOL busy = _host.settingsIsIndexing;
            text = !there ? @"Missing" : busy ? @"Indexing…" : @"Indexed";
            color = !there ? NSColor.systemRedColor : busy ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
        }
    } else {
        text = [_excludes[(NSUInteger)row][0] stringByAbbreviatingWithTildeInPath];
    }
    NSTextField *l = MakeLabel(text, 13, NSFontWeightRegular, color);
    l.alignment = align;
    l.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return l;
}

// ---- actions

- (void)loginToggled:(NSSwitch *)sw {
    [_host toggleLogin];
    sw.state = _host.settingsLoginEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)addFolder { [_host chooseFolder]; }
- (void)reindex { [_host reindexAll]; }

- (void)removeSelectedFolder {
    NSInteger r = _foldersTable.selectedRow;
    if (r < 0 || r >= (NSInteger)_roots.count) return;
    [_host removeFolder:_roots[(NSUInteger)r][0]];
}

- (void)addPattern {
    NSString *p = [_excludeField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (p.length == 0) return;
    if ([p hasPrefix:@"~"]) p = p.stringByExpandingTildeInPath;
    _excludeField.stringValue = @"";
    [_host addExclude:p];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)cmd {
    if (cmd == @selector(insertNewline:)) { [self addPattern]; return YES; }
    return NO;
}

- (void)addExcludedFolder {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseDirectories = YES;
    op.canChooseFiles = NO;
    op.prompt = @"Exclude";
    op.message = @"Choose a folder for Seek to skip";
    if ([op runModal] == NSModalResponseOK && op.URL) [_host addExclude:op.URL.path];
}

- (void)removeSelectedExclude {
    NSInteger r = _excludesTable.selectedRow;
    if (r < 0 || r >= (NSInteger)_excludes.count) return;
    [_host removeExclude:_excludes[(NSUInteger)r][0]];
}

- (void)revealDB {
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:self.dbPath] ]];
}
@end

// ------------------------------------------------------------------ first-run onboarding

@protocol SeekOnboardingHost <SeekSettingsHost>
- (void)startOnboardingIndexing:(NSArray<NSString *> *)paths;
- (void)openSettingsFromOnboarding;
- (BOOL)menuBarIconVisible;
- (void)setMenuBarIconVisible:(BOOL)visible;
@end

static NSView *Keycap(NSString *text, CGFloat w, CGFloat h) {
    SeekFlipView *v = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    v.wantsLayer = YES;
    v.layer.cornerRadius = 8;
    v.layer.borderWidth = 1;
    v.layer.borderColor = [NSColor.labelColor colorWithAlphaComponent:0.18].CGColor;
    v.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    NSTextField *l = MakeLabel(text, 15, NSFontWeightMedium, NSColor.labelColor);
    l.alignment = NSTextAlignmentCenter;
    l.frame = NSMakeRect(0, (h - 18) / 2, w, 18);
    [v addSubview:l];
    return v;
}

static NSView *Divider(CGFloat x, CGFloat y, CGFloat w) {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(x, y, w, 1)];
    b.boxType = NSBoxSeparator;
    return b;
}

@interface SeekOnboarding : NSObject
- (instancetype)initWithHost:(id<SeekOnboardingHost>)host;
- (void)show;
- (void)progress:(uint64_t)seen;
- (void)folderStarted:(NSUInteger)i;
- (void)folderDone:(NSUInteger)i files:(uint64_t)n;
- (void)finished;
@end

@implementation SeekOnboarding {
    __weak id<SeekOnboardingHost> _host;
    NSWindow *_win;
    SeekFlipView *_body, *_footer;
    NSInteger _step;
    NSMutableArray<NSMutableDictionary *> *_choices; // path, name, hint, on, recommended
    NSMutableDictionary<NSString *, NSString *> *_access; // path -> allowed | denied
    NSArray<NSString *> *_plan;                       // folders that will be indexed
    NSMutableArray<NSString *> *_planState;           // waiting | active | done
    uint64_t _base, _current;
    BOOL _allDone;
    // step 5
    NSProgressIndicator *_bar;
    NSTextField *_readyTitle, *_readyCount;
    SeekFlipView *_planRows;
    NSTextField *_headline;
}

static const CGFloat kOW = 680, kOH = 540, kOTitle = 40, kOFooter = 72, kOPad = 56;

- (instancetype)initWithHost:(id<SeekOnboardingHost>)host {
    if (!(self = [super init])) return nil;
    _host = host;
    _access = [NSMutableDictionary dictionary];
    NSString *home = NSHomeDirectory();
    _choices = [NSMutableArray array];
    for (NSArray *d in @[ @[ @"Documents", @YES ], @[ @"Desktop", @YES ], @[ @"Downloads", @YES ], @[ @"Pictures", @YES ] ])
        [_choices addObject:[@{@"path" : [home stringByAppendingPathComponent:d[0]], @"name" : d[0],
                               @"hint" : [@"~/" stringByAppendingString:d[0]], @"on" : @YES, @"rec" : d[1]} mutableCopy]];
    [_choices addObject:[@{@"path" : home, @"name" : @"Entire home folder", @"hint" : @"Everything in ~ except Library",
                           @"on" : @NO, @"rec" : @NO, @"home" : @YES} mutableCopy]];

    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kOW, kOH)
                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                 NSWindowStyleMaskFullSizeContentView
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    _win.titlebarAppearsTransparent = YES;
    _win.titleVisibility = NSWindowTitleHidden;
    _win.movableByWindowBackground = YES;
    _win.releasedWhenClosed = NO;
    [_win standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [_win standardWindowButton:NSWindowZoomButton].hidden = YES;
    [_win center];

    SeekFlipView *root = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, 0, kOW, kOH)];
    _body = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, kOTitle, kOW, kOH - kOTitle - kOFooter)];
    _footer = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, kOH - kOFooter, kOW, kOFooter)];
    [root addSubview:_body];
    [root addSubview:_footer];
    _win.contentView = root;
    return self;
}

- (void)show {
    [self showStep:0];
    [_win makeKeyAndOrderFront:nil];
}

- (void)clear:(NSView *)v {
    for (NSView *sub in [v.subviews copy]) [sub removeFromSuperview];
}

- (NSColor *)accent { return NSColor.controlAccentColor; }

- (void)heading:(NSString *)title sub:(NSString *)sub {
    NSTextField *h = MakeLabel(title, 26, NSFontWeightBold, NSColor.labelColor);
    h.frame = NSMakeRect(kOPad, 4, kOW - kOPad * 2, 32);
    NSTextField *s = [NSTextField wrappingLabelWithString:sub];
    s.font = [NSFont systemFontOfSize:14];
    s.textColor = NSColor.secondaryLabelColor;
    s.frame = NSMakeRect(kOPad, 42, kOW - kOPad * 2, 40);
    [_body addSubview:h];
    [_body addSubview:s];
}

- (NSButton *)button:(NSString *)title primary:(BOOL)primary action:(SEL)sel {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.controlSize = NSControlSizeLarge;
    if (primary) {
        b.bezelColor = self.accent;
        b.keyEquivalent = @"\r";
    }
    [b sizeToFit];
    NSRect f = b.frame;
    f.size.width = MAX(f.size.width + 8, primary ? 110 : 80);
    b.frame = f;
    return b;
}

- (void)buildFooter {
    [self clear:_footer];
    [_footer addSubview:Divider(0, 0, kOW)];
    for (int i = 0; i < 5; i++) {
        NSView *d = [[NSView alloc] initWithFrame:NSMakeRect(28 + i * 14, kOFooter / 2 - 3.5, 7, 7)];
        d.wantsLayer = YES;
        d.layer.cornerRadius = 3.5;
        d.layer.backgroundColor = (i == _step ? self.accent : [NSColor.labelColor colorWithAlphaComponent:0.18]).CGColor;
        [_footer addSubview:d];
    }
    NSString *nextTitle = @[ @"Get Started", @"Continue", @"Continue", @"Start Indexing", @"Done" ][_step];
    NSButton *next = [self button:nextTitle primary:YES action:@selector(next)];
    next.frame = NSMakeRect(kOW - 28 - next.frame.size.width, (kOFooter - next.frame.size.height) / 2, next.frame.size.width, next.frame.size.height);
    [_footer addSubview:next];
    CGFloat x = next.frame.origin.x - 10;
    if (_step == 4) {
        NSButton *prefs = [self button:@"Open Settings" primary:NO action:@selector(openSettings)];
        x -= prefs.frame.size.width;
        prefs.frame = NSMakeRect(x, next.frame.origin.y, prefs.frame.size.width, next.frame.size.height);
        [_footer addSubview:prefs];
    } else if (_step > 0) {
        NSButton *back = [self button:@"Back" primary:NO action:@selector(back)];
        x -= back.frame.size.width;
        back.frame = NSMakeRect(x, next.frame.origin.y, back.frame.size.width, next.frame.size.height);
        [_footer addSubview:back];
    }
    if (_step == 1) next.enabled = [self effectivePaths].count > 0;
}

- (void)next {
    if (_step == 3) { [self startIndexing]; return; }
    if (_step == 4) { [_win close]; return; }
    [self showStep:_step + 1];
}
- (void)back { if (_step > 0) [self showStep:_step - 1]; }
- (void)openSettings { [_host openSettingsFromOnboarding]; }

- (void)showStep:(NSInteger)step {
    _step = step;
    [self clear:_body];
    switch (step) {
        case 0: [self buildWelcome]; break;
        case 1: [self buildFolders]; break;
        case 2: [self buildAccess]; break;
        case 3: [self buildHotkey]; break;
        default: [self buildReady]; break;
    }
    [self buildFooter];
}

// ---- 1 Welcome

- (void)buildWelcome {
    SeekFlipView *icon = [[SeekFlipView alloc] initWithFrame:NSMakeRect((kOW - 92) / 2, 8, 92, 92)];
    icon.wantsLayer = YES;
    icon.layer.cornerRadius = 22;
    icon.layer.backgroundColor = self.accent.CGColor;
    NSImageView *g = SymbolView(@"magnifyingglass", 44, NSColor.whiteColor);
    g.frame = NSMakeRect(20, 20, 52, 52);
    [icon addSubview:g];
    [_body addSubview:icon];

    NSTextField *t = MakeLabel(@"Welcome to Seek", 30, NSFontWeightBold, NSColor.labelColor);
    t.alignment = NSTextAlignmentCenter;
    t.frame = NSMakeRect(0, 114, kOW, 38);
    NSTextField *s = MakeLabel(@"Find any file on your Mac the moment you think of it.", 15, NSFontWeightRegular, NSColor.secondaryLabelColor);
    s.alignment = NSTextAlignmentCenter;
    s.frame = NSMakeRect(0, 156, kOW, 20);
    [_body addSubview:t];
    [_body addSubview:s];

    NSArray *feats = @[
        @[ @"bolt", @"Instant", @"Results appear as you type, in well under a tenth of a second." ],
        @[ @"square.stack.3d.up", @"One index for everything", @"File names, contents, metadata and duplicates, searched together." ],
        @[ @"lock", @"Private by design", @"Seek works fully offline. Nothing ever leaves your Mac." ],
    ];
    CGFloat y = 208;
    for (NSArray *f in feats) {
        SeekCard *box = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad + 8, y, 40, 40)];
        NSImageView *ic = SymbolView(f[0], 18, self.accent);
        ic.frame = NSMakeRect(8, 8, 24, 24);
        [box addSubview:ic];
        NSTextField *ft = MakeLabel(f[1], 14, NSFontWeightSemibold, NSColor.labelColor);
        ft.frame = NSMakeRect(kOPad + 64, y, 460, 18);
        NSTextField *fb = MakeLabel(f[2], 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
        fb.frame = NSMakeRect(kOPad + 64, y + 20, 460, 18);
        for (NSView *v in @[ box, ft, fb ]) [_body addSubview:v];
        y += 62;
    }
}

// ---- 2 Folders

- (NSArray<NSString *> *)effectivePaths {
    for (NSDictionary *c in _choices)
        if ([c[@"home"] boolValue] && [c[@"on"] boolValue]) return @[ c[@"path"] ]; // home covers the rest
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *c in _choices)
        if ([c[@"on"] boolValue]) [out addObject:c[@"path"]];
    return out;
}

- (void)buildFolders {
    [self heading:@"What should Seek search?" sub:@"Choose the folders to index. You can change this any time in Settings."];
    CGFloat rowH = 46;
    CGFloat contentH = (CGFloat)(_choices.count + 1) * rowH;
    CGFloat cardH = MIN(contentH, 276);
    SeekCard *card = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad, 96, kOW - kOPad * 2, cardH)];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSInsetRect(card.bounds, 1, 1)];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = contentH > cardH;
    sv.autohidesScrollers = YES;
    CGFloat w = sv.frame.size.width;
    SeekFlipView *doc = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, 0, w, contentH)];
    for (NSUInteger i = 0; i < _choices.count; i++) {
        NSDictionary *c = _choices[i];
        CGFloat y = i * rowH;
        NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleChoice:)];
        cb.tag = (NSInteger)i;
        cb.state = [c[@"on"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        cb.frame = NSMakeRect(14, y + 13, 20, 20);
        NSImageView *ic = SymbolView(@"folder", 20, self.accent);
        ic.frame = NSMakeRect(44, y + 12, 24, 22);
        NSTextField *name = MakeLabel(c[@"name"], 14, NSFontWeightMedium, NSColor.labelColor);
        name.frame = NSMakeRect(78, y + 6, w - 78 - 130, 18);
        NSTextField *hint = MakeLabel(c[@"hint"], 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        hint.lineBreakMode = NSLineBreakByTruncatingMiddle;
        hint.frame = NSMakeRect(78, y + 24, w - 78 - 130, 16);
        for (NSView *v in @[ cb, ic, name, hint ]) [doc addSubview:v];
        if ([c[@"rec"] boolValue]) {
            NSTextField *tag = MakeLabel(@"Recommended", 11, NSFontWeightSemibold, self.accent);
            tag.alignment = NSTextAlignmentRight;
            tag.frame = NSMakeRect(w - 120, y + 14, 106, 16);
            [doc addSubview:tag];
        }
        [doc addSubview:Divider(0, y + rowH - 1, w)];
    }
    NSButton *add = [NSButton buttonWithTitle:@"  Add Folder…" target:self action:@selector(addFolder)];
    add.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];
    add.imagePosition = NSImageLeft;
    add.bordered = NO;
    add.contentTintColor = self.accent;
    add.font = [NSFont systemFontOfSize:14];
    add.frame = NSMakeRect(40, (CGFloat)_choices.count * rowH + 8, 160, 30);
    [doc addSubview:add];
    sv.documentView = doc;
    [card addSubview:sv];
    [_body addSubview:card];

    NSTextField *note = [NSTextField wrappingLabelWithString:@"Seek skips caches, .git, node_modules and your Library folder automatically."];
    note.font = [NSFont systemFontOfSize:12];
    note.textColor = NSColor.tertiaryLabelColor;
    note.frame = NSMakeRect(kOPad + 2, 96 + cardH + 12, kOW - kOPad * 2, 34);
    [_body addSubview:note];
}

- (void)toggleChoice:(NSButton *)b {
    _choices[(NSUInteger)b.tag][@"on"] = @(b.state == NSControlStateValueOn);
    [self buildFooter];
}

- (void)addFolder {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseDirectories = YES;
    op.canChooseFiles = NO;
    op.prompt = @"Add";
    op.message = @"Choose a folder for Seek to index";
    if ([op runModal] != NSModalResponseOK || !op.URL) return;
    NSString *path = op.URL.path;
    for (NSMutableDictionary *c in _choices)
        if ([c[@"path"] isEqualToString:path]) { c[@"on"] = @YES; [self showStep:1]; return; }
    [_choices insertObject:[@{@"path" : path, @"name" : path.lastPathComponent,
                              @"hint" : path.stringByAbbreviatingWithTildeInPath, @"on" : @YES, @"rec" : @NO} mutableCopy]
                   atIndex:_choices.count - 1]; // keep "Entire home folder" last
    [self showStep:1];
}

// ---- 3 Access

static BOOL IsProtectedFolder(NSString *path) {
    NSString *home = NSHomeDirectory();
    for (NSString *n in @[ @"Desktop", @"Documents", @"Downloads" ])
        if ([path isEqualToString:[home stringByAppendingPathComponent:n]]) return YES;
    return NO;
}

- (void)buildAccess {
    [self heading:@"Allow access to your files"
              sub:@"macOS asks before an app reads your folders. Seek only reads names, sizes and dates, plus file contents in the folders you chose."];
    NSArray<NSString *> *paths = [self effectivePaths];
    NSTextField *sec = MakeLabel(@"FOLDER ACCESS", 11, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    sec.frame = NSMakeRect(kOPad + 2, 96, 300, 14);
    [_body addSubview:sec];

    CGFloat rowH = 40, contentH = MAX((CGFloat)paths.count, 1) * rowH, cardH = MIN(contentH, 160);
    SeekCard *card = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad, 114, kOW - kOPad * 2, cardH)];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSInsetRect(card.bounds, 1, 1)];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = contentH > cardH;
    sv.autohidesScrollers = YES;
    CGFloat w = sv.frame.size.width;
    SeekFlipView *doc = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, 0, w, contentH)];
    for (NSUInteger i = 0; i < paths.count; i++) {
        NSString *path = paths[i];
        CGFloat y = i * rowH;
        // Folders macOS doesn't gate can be checked silently; the three protected ones need a prompt.
        if (!_access[path] && !IsProtectedFolder(path) && [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil])
            _access[path] = @"allowed";
        NSImageView *ic = SymbolView(@"folder", 18, self.accent);
        ic.frame = NSMakeRect(14, y + 10, 22, 20);
        NSTextField *name = MakeLabel(path.stringByAbbreviatingWithTildeInPath, 14, NSFontWeightRegular, NSColor.labelColor);
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        name.frame = NSMakeRect(46, y + 11, w - 46 - 120, 18);
        [doc addSubview:ic];
        [doc addSubview:name];
        NSString *state = _access[path];
        if ([state isEqualToString:@"allowed"]) {
            NSImageView *ck = SymbolView(@"checkmark.circle.fill", 15, NSColor.systemGreenColor);
            ck.frame = NSMakeRect(w - 104, y + 12, 16, 16);
            NSTextField *l = MakeLabel(@"Allowed", 13, NSFontWeightSemibold, NSColor.systemGreenColor);
            l.frame = NSMakeRect(w - 84, y + 11, 70, 18);
            [doc addSubview:ck];
            [doc addSubview:l];
        } else if ([state isEqualToString:@"denied"]) {
            NSButton *open = [NSButton buttonWithTitle:@"Denied · Settings" target:self action:@selector(openFilesPrivacy)];
            open.bezelStyle = NSBezelStyleInline;
            open.contentTintColor = NSColor.systemRedColor;
            open.frame = NSMakeRect(w - 150, y + 8, 138, 24);
            [doc addSubview:open];
        } else {
            NSButton *allow = [NSButton buttonWithTitle:@"Allow…" target:self action:@selector(askAccess:)];
            allow.tag = (NSInteger)i;
            allow.controlSize = NSControlSizeSmall;
            allow.frame = NSMakeRect(w - 84, y + 8, 70, 24);
            [doc addSubview:allow];
        }
        [doc addSubview:Divider(0, y + rowH - 1, w)];
    }
    sv.documentView = doc;
    [card addSubview:sv];
    [_body addSubview:card];

    CGFloat y2 = 114 + cardH + 22;
    NSTextField *opt = MakeLabel(@"OPTIONAL", 11, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    opt.frame = NSMakeRect(kOPad + 2, y2, 300, 14);
    [_body addSubview:opt];
    SeekCard *fda = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad, y2 + 18, kOW - kOPad * 2, 64)];
    NSImageView *lock = SymbolView(@"lock", 20, NSColor.secondaryLabelColor);
    lock.frame = NSMakeRect(14, 20, 24, 24);
    NSTextField *ft = MakeLabel(@"Full Disk Access", 14, NSFontWeightMedium, NSColor.labelColor);
    ft.frame = NSMakeRect(50, 10, 280, 18);
    NSTextField *fb = [NSTextField wrappingLabelWithString:@"Lets Seek index protected places like Mail and Messages. You can skip this and add it later."];
    fb.font = [NSFont systemFontOfSize:12];
    fb.textColor = NSColor.tertiaryLabelColor;
    fb.frame = NSMakeRect(50, 28, 270, 34);
    NSButton *open = [NSButton buttonWithTitle:@"Open System Settings" target:self action:@selector(openFullDiskAccess)];
    open.controlSize = NSControlSizeSmall;
    open.frame = NSMakeRect(fda.bounds.size.width - 166, 20, 154, 24);
    for (NSView *v in @[ lock, ft, fb, open ]) [fda addSubview:v];
    [_body addSubview:fda];
}

- (void)askAccess:(NSButton *)b {
    NSString *path = [self effectivePaths][(NSUInteger)b.tag];
    b.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Listing the folder is what makes macOS show its permission prompt.
        BOOL ok = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil] != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_access[path] = ok ? @"allowed" : @"denied";
            if (self->_step == 2) [self showStep:2];
        });
    });
}

- (void)openFilesPrivacy {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"]];
}
- (void)openFullDiskAccess {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
}

// ---- 4 Hotkey

- (void)buildHotkey {
    [self heading:@"Summon Seek from anywhere"
              sub:@"Press the shortcut in any app. The search bar appears instantly and never steals your place."];
    SeekFlipView *stage = [[SeekFlipView alloc] initWithFrame:NSMakeRect(kOPad, 96, kOW - kOPad * 2, 156)];
    stage.wantsLayer = YES;
    stage.layer.cornerRadius = 12;
    stage.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.07].CGColor;
    SeekCard *bar = [[SeekCard alloc] initWithFrame:NSMakeRect(28, 24, stage.bounds.size.width - 56, 52)];
    NSImageView *mag = SymbolView(@"magnifyingglass", 18, NSColor.secondaryLabelColor);
    mag.frame = NSMakeRect(16, 15, 22, 22);
    NSTextField *ph = MakeLabel(@"Search files, folders and contents", 20, NSFontWeightLight, NSColor.tertiaryLabelColor);
    ph.frame = NSMakeRect(48, 13, bar.frame.size.width - 64, 26);
    [bar addSubview:mag];
    [bar addSubview:ph];
    [stage addSubview:bar];
    NSView *k1 = Keycap(@"⌥ Option", 88, 38), *k2 = Keycap(@"Space", 120, 38);
    CGFloat total = 88 + 8 + 120, x0 = (stage.bounds.size.width - total) / 2;
    k1.frame = NSMakeRect(x0, 96, 88, 38);
    k2.frame = NSMakeRect(x0 + 96, 96, 120, 38);
    [stage addSubview:k1];
    [stage addSubview:k2];
    [_body addSubview:stage];

    SeekCard *opts = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad, 270, kOW - kOPad * 2, 100)];
    NSArray *rows = @[
        @[ @"Launch Seek at login", @"Stays in the menu bar so the shortcut is always ready", @([_host settingsLoginEnabled]), @"login" ],
        @[ @"Show icon in the menu bar", @"Quick access to settings and indexing status", @([_host menuBarIconVisible]), @"menubar" ],
    ];
    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = i * 50;
        NSTextField *l = MakeLabel(rows[i][0], 14, NSFontWeightRegular, NSColor.labelColor);
        l.frame = NSMakeRect(14, y + 7, 380, 18);
        NSTextField *h = MakeLabel(rows[i][1], 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        h.frame = NSMakeRect(14, y + 26, 400, 16);
        NSSwitch *sw = [NSSwitch new];
        sw.controlSize = NSControlSizeSmall;
        sw.state = [rows[i][2] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        sw.identifier = rows[i][3];
        sw.target = self;
        sw.action = @selector(optionToggled:);
        [sw sizeToFit];
        sw.frame = NSMakeRect(opts.bounds.size.width - 14 - sw.frame.size.width, y + (50 - sw.frame.size.height) / 2, sw.frame.size.width, sw.frame.size.height);
        for (NSView *v in @[ l, h, sw ]) [opts addSubview:v];
        if (i == 0) [opts addSubview:Divider(0, 49, opts.bounds.size.width)];
    }
    [_body addSubview:opts];
}

- (void)optionToggled:(NSSwitch *)sw {
    if ([sw.identifier isEqualToString:@"login"]) {
        [_host toggleLogin];
        sw.state = [_host settingsLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    } else {
        [_host setMenuBarIconVisible:sw.state == NSControlStateValueOn];
    }
}

// ---- 5 Indexing

- (void)startIndexing {
    _plan = [self effectivePaths];
    _planState = [NSMutableArray array];
    for (NSUInteger i = 0; i < _plan.count; i++) [_planState addObject:@"waiting"];
    _base = _current = 0;
    _allDone = NO;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboarded"];
    [self showStep:4];
    [_host startOnboardingIndexing:_plan];
}

- (void)buildReady {
    _headline = nil;
    [self heading:@"Building your index"
              sub:@"You can start searching right away. Results get more complete as indexing finishes."];
    CGFloat w = kOW - kOPad * 2;
    CGFloat rows = (CGFloat)MIN(_plan.count, 5);
    SeekCard *card = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad, 96, w, 84 + rows * 26)];
    _readyTitle = MakeLabel(@"Indexing…", 14, NSFontWeightSemibold, NSColor.labelColor);
    _readyTitle.frame = NSMakeRect(16, 14, 240, 18);
    _readyCount = MakeLabel(@"", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _readyCount.alignment = NSTextAlignmentRight;
    _readyCount.frame = NSMakeRect(w - 216, 15, 200, 18);
    _bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(16, 42, w - 32, 10)];
    _bar.style = NSProgressIndicatorStyleBar;
    _bar.indeterminate = NO;
    _bar.minValue = 0;
    _bar.maxValue = 1;
    _planRows = [[SeekFlipView alloc] initWithFrame:NSMakeRect(16, 66, w - 32, rows * 26)];
    for (NSView *v in @[ _readyTitle, _readyCount, _bar, _planRows ]) [card addSubview:v];
    [_body addSubview:card];

    SeekCard *tip = [[SeekCard alloc] initWithFrame:NSMakeRect(kOPad, 96 + card.frame.size.height + 20, w, 64)];
    NSView *k1 = Keycap(@"⌥", 36, 32), *k2 = Keycap(@"Space", 64, 32);
    k1.frame = NSMakeRect(16, 16, 36, 32);
    k2.frame = NSMakeRect(58, 16, 64, 32);
    NSTextField *t = [NSTextField wrappingLabelWithString:@"Try it now. Seek lives in your menu bar, so it is always one shortcut away."];
    t.font = [NSFont systemFontOfSize:13];
    t.textColor = NSColor.secondaryLabelColor;
    t.frame = NSMakeRect(138, 12, w - 154, 40);
    for (NSView *v in @[ k1, k2, t ]) [tip addSubview:v];
    [_body addSubview:tip];
    [self refreshReady];
}

- (void)refreshReady {
    if (_step != 4 || !_bar) return;
    NSUInteger n = _plan.count, done = 0;
    for (NSString *s in _planState) if ([s isEqualToString:@"done"]) done++;
    uint64_t files = _base + _current;
    _bar.doubleValue = _allDone ? 1 : (n ? ((double)done + (done < n ? 0.5 : 0)) / (double)n : 0);
    _readyTitle.stringValue = _allDone ? @"Your index is ready" : @"Indexing…";
    _readyCount.stringValue = [NSString stringWithFormat:@"%@ files%@", FormatCount(files), _allDone ? @"" : @" so far"];
    for (NSView *v in [_planRows.subviews copy]) [v removeFromSuperview];
    CGFloat w = _planRows.bounds.size.width;
    for (NSUInteger i = 0; i < MIN(n, 5); i++) {
        NSString *state = _planState[i];
        CGFloat y = i * 26;
        NSView *mark;
        if ([state isEqualToString:@"done"]) {
            mark = SymbolView(@"checkmark.circle.fill", 15, NSColor.systemGreenColor);
            mark.frame = NSMakeRect(0, y + 4, 16, 16);
        } else if ([state isEqualToString:@"active"]) {
            NSProgressIndicator *sp = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, y + 4, 16, 16)];
            sp.style = NSProgressIndicatorStyleSpinning;
            sp.controlSize = NSControlSizeSmall;
            sp.indeterminate = YES;
            [sp startAnimation:nil];
            mark = sp;
        } else {
            mark = [[NSView alloc] initWithFrame:NSMakeRect(4, y + 8, 8, 8)];
            mark.wantsLayer = YES;
            mark.layer.cornerRadius = 4;
            mark.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.2].CGColor;
        }
        BOOL waiting = [state isEqualToString:@"waiting"];
        NSTextField *name = MakeLabel(_plan[i].stringByAbbreviatingWithTildeInPath, 13, NSFontWeightRegular,
                                      waiting ? NSColor.tertiaryLabelColor : NSColor.labelColor);
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        name.frame = NSMakeRect(26, y + 3, w - 130, 18);
        NSTextField *st = MakeLabel([state isEqualToString:@"done"] ? @"Done" : waiting ? @"Waiting" : @"Indexing…", 13,
                                    NSFontWeightRegular, NSColor.tertiaryLabelColor);
        st.alignment = NSTextAlignmentRight;
        st.frame = NSMakeRect(w - 100, y + 3, 100, 18);
        for (NSView *v in @[ mark, name, st ]) [_planRows addSubview:v];
    }
}

- (void)progress:(uint64_t)seen { _current = seen; [self refreshReady]; }
- (void)folderStarted:(NSUInteger)i { if (i < _planState.count) { _planState[i] = @"active"; _current = 0; [self refreshReady]; } }
- (void)folderDone:(NSUInteger)i files:(uint64_t)n {
    if (i >= _planState.count) return;
    _planState[i] = @"done";
    _base += n;
    _current = 0;
    [self refreshReady];
}
- (void)finished { _allDone = YES; [self refreshReady]; }
@end

// Sample content only: duplicate detection (content hashing) is not in the core yet.
static NSWindow *BuildDuplicatesWindow(void) {
    const CGFloat W = 760, H = 580, pad = 20, cw = W - pad * 2;
    NSWindow *win = MakeWindow(@"Duplicates (preview)", W, H);
    SeekFlipView *root = [[SeekFlipView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];

    NSTextField *query = MakeLabel(@"kind:image year:2019 is:duplicate", 20, NSFontWeightRegular, NSColor.labelColor);
    query.frame = NSMakeRect(pad, 18, cw, 26);
    [root addSubview:query];
    CGFloat cx = pad;
    for (NSString *c in @[ @"Kind: Image", @"Year: 2019", @"Duplicates only" ]) {
        SeekChip *chip = [[SeekChip alloc] initWithTitle:c caret:![c hasPrefix:@"Dup"]];
        chip.frame = NSMakeRect(cx, 54, chip.frame.size.width, 26);
        cx += chip.frame.size.width + 8;
        [root addSubview:chip];
    }

    SeekCard *summary = [[SeekCard alloc] initWithFrame:NSMakeRect(pad, 94, cw, 62)];
    NSTextField *big = MakeLabel(@"38 groups", 24, NSFontWeightSemibold, NSColor.labelColor);
    big.frame = NSMakeRect(14, 14, 150, 32);
    NSTextField *meta = MakeLabel(@"76 files · 412 MB recoverable\nKeeping the oldest copy of each by default", 12,
                                  NSFontWeightRegular, NSColor.secondaryLabelColor);
    meta.maximumNumberOfLines = 2;
    meta.frame = NSMakeRect(172, 12, 280, 38);
    [summary addSubview:big];
    [summary addSubview:meta];
    [summary addSubview:PushButton(@"Review all", NSMakeRect(cw - 12 - 170 - 8 - 90, 17, 90, 28), NO)];
    [summary addSubview:PushButton(@"Move 38 extras to Trash", NSMakeRect(cw - 12 - 170, 17, 170, 28), YES)];
    [root addSubview:summary];

    NSArray *groups = @[
        @[ @"IMG_2231.jpg", @"4.1 MB · 2 copies · Aug 2019", @[
            @[ @"~/Pictures/2019/Lisbon/IMG_2231.jpg", @"12 Aug 2019", @YES ],
            @[ @"~/Desktop/Backup old/IMG_2231.jpg", @"03 Jan 2021", @NO ] ] ],
        @[ @"IMG_2240.jpg", @"3.8 MB · 3 copies · Aug 2019", @[
            @[ @"~/Pictures/2019/Lisbon/IMG_2240.jpg", @"12 Aug 2019", @YES ],
            @[ @"~/Dropbox/Camera Uploads/IMG_2240.jpg", @"13 Aug 2019", @NO ],
            @[ @"~/Desktop/Backup old/IMG_2240.jpg", @"03 Jan 2021", @NO ] ] ],
        @[ @"wedding-final.heic", @"2.9 MB · 2 copies · Jun 2019", @[
            @[ @"~/Pictures/Events/Wedding/wedding-final.heic", @"22 Jun 2019", @YES ],
            @[ @"~/Downloads/wedding-final.heic", @"30 Jun 2019", @NO ] ] ],
    ];
    CGFloat y = 170;
    for (NSArray *g in groups) {
        NSArray *copies = g[2];
        SeekCard *card = [[SeekCard alloc] initWithFrame:NSMakeRect(pad, y, cw, 44 + copies.count * 28)];
        NSView *sw = [[NSView alloc] initWithFrame:NSMakeRect(12, 8, 28, 28)];
        sw.wantsLayer = YES;
        sw.layer.cornerRadius = 6;
        sw.layer.backgroundColor = [NSColor.tertiaryLabelColor colorWithAlphaComponent:0.5].CGColor;
        NSTextField *n = MakeLabel(g[0], 14, NSFontWeightSemibold, NSColor.labelColor);
        n.frame = NSMakeRect(50, 12, 300, 20);
        NSTextField *m = MakeLabel(g[1], 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
        m.alignment = NSTextAlignmentRight;
        m.frame = NSMakeRect(cw - 12 - 240, 14, 240, 16);
        NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 43, cw, 1)];
        sep.boxType = NSBoxSeparator;
        for (NSView *v in @[ sw, n, m, sep ]) [card addSubview:v];
        for (NSUInteger i = 0; i < copies.count; i++) {
            BOOL keep = [copies[i][2] boolValue];
            CGFloat ry = 44 + i * 28;
            NSImageView *dot = SymbolView(keep ? @"checkmark.circle.fill" : @"circle", 14,
                                          keep ? NSColor.systemGreenColor : NSColor.tertiaryLabelColor);
            dot.frame = NSMakeRect(12, ry + 6, 16, 16);
            NSTextField *p = MakeLabel(copies[i][0], 12, NSFontWeightRegular, NSColor.labelColor);
            p.lineBreakMode = NSLineBreakByTruncatingHead;
            p.frame = NSMakeRect(36, ry + 6, cw - 36 - 170, 16);
            NSTextField *d = MakeLabel(copies[i][1], 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
            d.alignment = NSTextAlignmentRight;
            d.frame = NSMakeRect(cw - 12 - 150, ry + 6, 90, 16);
            NSTextField *t = MakeLabel(keep ? @"Keep" : @"Extra", 12, NSFontWeightSemibold,
                                       keep ? NSColor.systemGreenColor : NSColor.systemOrangeColor);
            t.alignment = NSTextAlignmentRight;
            t.frame = NSMakeRect(cw - 12 - 50, ry + 6, 50, 16);
            for (NSView *v in @[ dot, p, d, t ]) [card addSubview:v];
        }
        [root addSubview:card];
        y += card.frame.size.height + 10;
    }
    NSTextField *foot = MakeLabel(@"Nothing is deleted without confirmation. Trashed files can be restored from Finder.", 12,
                                  NSFontWeightRegular, NSColor.secondaryLabelColor);
    foot.frame = NSMakeRect(pad, H - 34, cw, 16);
    [root addSubview:foot];
    win.contentView = root;
    return win;
}

static void OnIndexProgress(void *ctx, uint64_t seen);

static OSStatus OnHotKey(EventHandlerCallRef next, EventRef event, void *userData);

// ------------------------------------------------------------------ app

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate, SeekPanelKeys, SeekOnboardingHost>
@end

@implementation AppDelegate {
    seek_index *_idx;
    SeekPanel *_panel;
    NSVisualEffectView *_effect;
    NSTextField *_field;
    NSTextField *_status;
    NSBox *_divider;
    NSScrollView *_scroll;
    NSTableView *_table;
    NSTextField *_empty;
    NSView *_glass;
    NSView *_hotkey;
    NSView *_chipsRow;
    NSArray<SeekChip *> *_chips;
    NSMutableSet<NSString *> *_thumbsPending;
    NSString *_detailPath;
    NSMutableDictionary<NSString *, NSDictionary *> *_facts;
    SeekChip *_clearChip;
    NSBox *_chipsDivider;
    NSBox *_footerDivider;
    NSBox *_listDivider;
    SeekDetail *_detail;
    NSView *_footer;
    NSView *_dot;
    NSTextField *_count;
    SeekSettings *_settings;
    SeekOnboarding *_onboarding;
    NSString *_statusLine;
    NSWindow *_duplicatesWindow;
    NSArray<SeekItem *> *_results;
    NSString *_lastQuery;
    dispatch_queue_t _searchQueue;
    dispatch_queue_t _indexQueue;
    BOOL _indexing;
    NSInteger _pendingJobs;
    uint64_t _indexSeen;
    NSStatusItem *_statusItem;
    NSMenuItem *_statusMenuLine;
    NSMenuItem *_loginItem;
    NSCache<NSString *, NSImage *> *_icons;
    NSRelativeDateTimeFormatter *_relDate;
    EventHotKeyRef _hotKey;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _results = @[];
    _lastQuery = @"";
    _icons = [NSCache new];
    _icons.countLimit = 500;
    _relDate = [NSRelativeDateTimeFormatter new];
    _relDate.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleAbbreviated;
    _searchQueue = dispatch_queue_create("seek.search", DISPATCH_QUEUE_SERIAL);
    _indexQueue = dispatch_queue_create("seek.index", dispatch_queue_attr_make_with_qos_class(
                                                          DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));

    _idx = seek_open(NULL);
    if (!_idx) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Seek couldn't open its index";
        a.informativeText = @"Check that ~/Library/Application Support/Seek is writable.";
        [NSApp activateIgnoringOtherApps:YES];
        [a runModal];
        [NSApp terminate:nil];
        return;
    }

    [self buildMainMenu];
    [self buildPanel];
    [self buildStatusItem];
    [self registerHotKey];

    BOOL hasRoots = seek_root_count(_idx) > 0;
    if (hasRoots) [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboarded"];
    _statusItem.visible = ![NSUserDefaults.standardUserDefaults boolForKey:@"hideMenuBarIcon"];
    if (!hasRoots && ![NSUserDefaults.standardUserDefaults boolForKey:@"onboarded"]) [self showOnboarding];
    [self reindexAll];
    [NSTimer scheduledTimerWithTimeInterval:kReindexInterval repeats:YES block:^(NSTimer *t) {
        [self reindexAll];
    }];
    [self updateStatus];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    if (_hotKey) UnregisterEventHotKey(_hotKey);
    // The index is left open on purpose: the process is exiting and indexing may still be running.
}

// ---------------------------------------------------------------- UI construction

- (void)buildMainMenu {
    // Invisible for a menu-bar app, but it's what makes Cmd+X/C/V/A/Z work in the search field.
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Seek" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [main addItem:appItem];

    NSMenuItem *editItem = [NSMenuItem new];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo" action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    NSMenuItem *redo = [edit addItemWithTitle:@"Redo" action:NSSelectorFromString(@"redo:") keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    [main addItem:editItem];
    NSApp.mainMenu = main;
}

- (void)buildPanel {
    _panel = [[SeekPanel alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, kFieldHeight)
                                          styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _panel.keyHandler = self;
    _panel.delegate = self;
    _panel.floatingPanel = YES;
    _panel.level = NSStatusWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = NO;
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.movableByWindowBackground = NO;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorIgnoresCycle;

    _effect = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kFieldHeight)];
    _effect.material = NSVisualEffectMaterialMenu;
    _effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _effect.state = NSVisualEffectStateActive; // stay frosted even though the app is never active
    _effect.maskImage = RoundedMask(14);
    _effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _panel.contentView = _effect;

    // Everything is laid out from the top; NSViewMinYMargin keeps it pinned there as the panel grows.
    NSImageView *glass = [NSImageView imageViewWithImage:
        [[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:@"Search"]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:20
                                                                                         weight:NSFontWeightMedium]]];
    glass.contentTintColor = NSColor.secondaryLabelColor;
    glass.frame = NSMakeRect(20, kFieldHeight - 44, 26, 26);
    _glass = glass;
    [_effect addSubview:glass];

    SeekChip *hotkey = [[SeekChip alloc] initWithTitle:@"⌥ Space" caret:NO];
    hotkey.frame = NSMakeRect(kWidth - 20 - hotkey.frame.size.width, kFieldHeight - 44 + 0, hotkey.frame.size.width, 26);
    _hotkey = hotkey;
    [_effect addSubview:hotkey];

    _field = [NSTextField new];
    _field.frame = NSMakeRect(56, kFieldHeight - 47, kWidth - 56 - 120, 32);
    _field.font = [NSFont systemFontOfSize:24 weight:NSFontWeightLight];
    _field.placeholderString = @"Seek";
    _field.bordered = NO;
    _field.bezeled = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.usesSingleLineMode = YES;
    _field.cell.scrollable = YES;
    _field.cell.wraps = NO;
    _field.delegate = self;
    [_effect addSubview:_field];

    _divider = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 1)];
    _divider.boxType = NSBoxSeparator;
    _divider.hidden = YES;
    [_effect addSubview:_divider];

    // Filter chips; any change re-runs the current query with the new filter.
    _chipsRow = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kChipsHeight)];
    _chipsRow.hidden = YES;
    __weak AppDelegate *weakSelf = self;
    void (^changed)(void) = ^{
        AppDelegate *me = weakSelf;
        [me layoutChips];
        [me runQuery:me->_field.stringValue];
    };
    NSArray *defs = @[
        @[ @"All items", @[ @"All items", @"Files only", @"Folders only" ] ],
        @[ @"Kind", @[ @"Any kind", @"Documents", @"Images", @"Audio", @"Video", @"Code", @"Archives" ] ],
        @[ @"Size", @[ @"Any size", @"Over 1 MB", @"Over 10 MB", @"Over 100 MB", @"Over 1 GB" ] ],
        @[ @"Modified", @[ @"Any time", @"Today", @"Past week", @"Past month", @"Past year" ] ],
    ];
    NSMutableArray<SeekChip *> *chips = [NSMutableArray array];
    for (NSArray *d in defs) {
        SeekChip *chip = [[SeekChip alloc] initWithTitle:d[0] caret:YES];
        chip.options = d[1];
        chip.onChange = changed;
        [chips addObject:chip];
    }
    SeekChip *dups = [[SeekChip alloc] initWithTitle:@"Duplicates only" caret:NO];
    dups.disabled = YES; // needs content hashing in the core
    dups.toolTip = @"Coming soon: needs duplicate detection";
    [chips addObject:dups];
    _chips = chips;
    for (SeekChip *c in chips) [_chipsRow addSubview:c];

    _clearChip = [[SeekChip alloc] initWithTitle:@"✕ Clear filters" caret:NO];
    _clearChip.onClick = ^{
        AppDelegate *me = weakSelf;
        for (SeekChip *c in me->_chips) c.selected = 0;
        changed();
    };
    [_chipsRow addSubview:_clearChip];
    [self layoutChips];
    [_effect addSubview:_chipsRow];

    NSBox *(^separator)(void) = ^NSBox *{
        NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 1)];
        b.boxType = NSBoxSeparator;
        b.hidden = YES;
        [self->_effect addSubview:b];
        return b;
    };
    _chipsDivider = separator();
    _footerDivider = separator();
    _listDivider = separator();

    _detail = [[SeekDetail alloc] initWithFrame:NSMakeRect(kListWidth + 1, 0, kWidth - kListWidth - 1, 300)];
    _detail.hidden = YES;
    _detail.openButton.target = self;
    _detail.openButton.action = @selector(openSelected);
    _detail.revealButton.target = self;
    _detail.revealButton.action = @selector(revealSelected);
    _detail.pathButton.target = self;
    _detail.pathButton.action = @selector(copyPathAction);
    [_effect addSubview:_detail];

    _footer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kFooterHeight)];
    _footer.hidden = YES;
    _count = MakeLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _count.frame = NSMakeRect(20, 8, 130, 16);
    _dot = [[NSView alloc] initWithFrame:NSMakeRect(160, 12, 7, 7)];
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = 3.5;
    _status = MakeLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _status.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _status.frame = NSMakeRect(173, 8, 220, 16);
    NSTextField *hints = MakeLabel(@"↑↓ Navigate    ↵ Open    ⌘↵ Reveal", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    hints.alignment = NSTextAlignmentRight;
    hints.frame = NSMakeRect(kWidth - 20 - 250, 8, 250, 16);
    for (NSView *v in @[ _count, _dot, _status, hints ]) [_footer addSubview:v];
    [_effect addSubview:_footer];

    _table = [NSTableView new];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    col.width = kListWidth - 4;
    [_table addTableColumn:col];
    _table.headerView = nil;
    _table.style = NSTableViewStylePlain;
    _table.rowHeight = kRowHeight;
    _table.intercellSpacing = NSMakeSize(0, 2);
    _table.backgroundColor = NSColor.clearColor;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.refusesFirstResponder = YES; // typing always stays in the search field
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(openSelected);

    _scroll = [NSScrollView new];
    _scroll.documentView = _table;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.contentInsets = NSEdgeInsetsMake(6, 0, 6, 0);
    _scroll.hidden = YES;
    [_effect addSubview:_scroll];

    _empty = [NSTextField labelWithString:@"No matches"];
    _empty.font = [NSFont systemFontOfSize:13];
    _empty.textColor = NSColor.secondaryLabelColor;
    _empty.alignment = NSTextAlignmentCenter;
    _empty.hidden = YES;
    [_effect addSubview:_empty];
}

- (void)buildStatusItem {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *img = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:@"Seek"];
    img.template = YES;
    _statusItem.button.image = img;

    NSMenu *m = [NSMenu new];
    NSMenuItem *show = [m addItemWithTitle:@"Show Seek" action:@selector(togglePanel) keyEquivalent:@" "];
    show.keyEquivalentModifierMask = NSEventModifierFlagOption;
    show.target = self;
    [m addItem:NSMenuItem.separatorItem];
    _statusMenuLine = [m addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _statusMenuLine.enabled = NO;
    NSMenuItem *welcome = [m addItemWithTitle:@"Welcome Tour…" action:@selector(showOnboarding) keyEquivalent:@""];
    welcome.target = self;
    NSMenuItem *dups = [m addItemWithTitle:@"Duplicates…" action:@selector(showDuplicates) keyEquivalent:@""];
    dups.target = self;
    NSMenuItem *prefs = [m addItemWithTitle:@"Settings…" action:@selector(showSettings) keyEquivalent:@","];
    prefs.target = self;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *add = [m addItemWithTitle:@"Index a Folder…" action:@selector(chooseFolder) keyEquivalent:@""];
    add.target = self;
    NSMenuItem *re = [m addItemWithTitle:@"Reindex Now" action:@selector(reindexAll) keyEquivalent:@""];
    re.target = self;
    _loginItem = [m addItemWithTitle:@"Launch at Login" action:@selector(toggleLogin) keyEquivalent:@""];
    _loginItem.target = self;
    _loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
                           ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Quit Seek" action:@selector(terminate:) keyEquivalent:@"q"];
    _statusItem.menu = m;
}

- (void)registerHotKey {
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&OnHotKey, 1, &spec, (__bridge void *)self, NULL);
    EventHotKeyID hid = {.signature = 0x5345454B /* 'SEEK' */, .id = 1};
    OSStatus err = RegisterEventHotKey(kVK_Space, optionKey, hid, GetApplicationEventTarget(), 0, &_hotKey);
    if (err != noErr) NSLog(@"Seek: Option+Space is taken by another app (error %d)", (int)err);
}

// ---------------------------------------------------------------- show / hide

- (void)togglePanel {
    if (_panel.isVisible) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel {
    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens)
        if (NSMouseInRect(mouse, s.frame, NO)) { screen = s; break; }
    NSRect vf = screen.visibleFrame;
    CGFloat top = NSMaxY(vf) - vf.size.height * 0.2;
    NSRect f = _panel.frame;
    f.origin.x = NSMidX(vf) - kWidth / 2;
    f.origin.y = top - f.size.height;
    [_panel setFrame:f display:NO];

    [self updateStatus];
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_field];
    [_field selectText:nil]; // like Spotlight: last query stays, selected, ready to overwrite
}

- (void)hidePanel {
    [_panel orderOut:nil];
}

- (void)windowDidResignKey:(NSNotification *)note {
    if (note.object != _panel) return;
    for (SeekChip *c in _chips)
        if (c.menuOpen) return; // a filter menu is open; the panel is still in use
    [self hidePanel];
}

// Resizes the panel to fit the results, keeping its top edge fixed.
- (void)layoutForResults {
    NSInteger rows = MIN((NSInteger)_results.count, kVisibleRows);
    BOOL hasBody = rows > 0;
    BOOL noMatches = _results.count == 0 && _lastQuery.length > 0;
    CGFloat bodyH = hasBody ? MAX(rows * (kRowHeight + 2) + 12, kBodyMinHeight) : 0;
    // Filters stay visible whenever there is search text, even with no matches, so they can be changed or cleared.
    BOOL showChips = hasBody || noMatches;
    CGFloat lowerH = hasBody ? bodyH + kFooterHeight : (noMatches ? 56 : 0); // everything below the chips row
    CGFloat extra = showChips ? kChipsHeight + lowerH : 0;
    CGFloat h = kFieldHeight + extra;

    // Frames are all set for the final height *before* the panel is resized: the window derives its
    // minimum size from the current subview frames, so stale ones would stop it from shrinking.
    _glass.frame = NSMakeRect(20, h - 44, 26, 26);
    _hotkey.frame = NSMakeRect(kWidth - 20 - _hotkey.frame.size.width, h - 44, _hotkey.frame.size.width, 26);
    _field.frame = NSMakeRect(56, h - 47, kWidth - 56 - 120, 32);
    _divider.hidden = extra == 0;
    _divider.frame = NSMakeRect(0, h - kFieldHeight, kWidth, 1);

    _chipsRow.hidden = !showChips;
    _chipsRow.frame = NSMakeRect(0, lowerH, kWidth, kChipsHeight);
    _chipsDivider.hidden = !showChips;
    _chipsDivider.frame = NSMakeRect(0, lowerH, kWidth, 1);
    _scroll.hidden = !hasBody;
    _scroll.frame = NSMakeRect(0, kFooterHeight, kListWidth, bodyH);
    _listDivider.hidden = !hasBody;
    _listDivider.frame = NSMakeRect(kListWidth, kFooterHeight, 1, bodyH);
    _detail.hidden = !hasBody;
    _detail.frame = NSMakeRect(kListWidth + 1, kFooterHeight, kWidth - kListWidth - 1, bodyH);
    _footerDivider.hidden = !hasBody;
    _footerDivider.frame = NSMakeRect(0, kFooterHeight - 1, kWidth, 1);
    _footer.hidden = !hasBody;
    _footer.frame = NSMakeRect(0, 0, kWidth, kFooterHeight - 1);

    _empty.hidden = !noMatches;
    _empty.frame = NSMakeRect(0, (lowerH - 18) / 2, kWidth, 18);
    [self updateDetail];

    NSRect f = _panel.frame;
    CGFloat top = NSMaxY(f);
    f.size.height = h;
    f.origin.y = top - h;
    [_panel setFrame:f display:YES];
    [_panel invalidateShadow];
}

// ---------------------------------------------------------------- search

- (void)controlTextDidChange:(NSNotification *)note {
    [self runQuery:_field.stringValue];
}

- (void)runQuery:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    unsigned long gen = atomic_fetch_add(&gQueryGeneration, 1) + 1;
    if (q.length == 0) {
        [self showResults:@[] query:@"" ms:0];
        return;
    }
    seek_index *idx = _idx;
    seek_filter filter = [self currentFilter];
    dispatch_async(_searchQueue, ^{
        if (atomic_load(&gQueryGeneration) != gen) return; // superseded while queued
        seek_result res[kMaxResults];
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        int n = seek_search_filtered(idx, q.UTF8String, &filter, res, kMaxResults);
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
        NSMutableArray<SeekItem *> *items = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(n, 0)];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (int i = 0; i < n; i++) {
            NSString *path = [fm stringWithFileSystemRepresentation:res[i].path length:strlen(res[i].path)];
            if (!path) continue;
            SeekItem *it = [SeekItem new];
            it.path = path;
            it.name = path.lastPathComponent;
            it.isDir = res[i].is_dir != 0;
            it.size = res[i].size;
            it.modified = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)res[i].mtime];
            [items addObject:it];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load(&gQueryGeneration) == gen) [self showResults:items query:q ms:ms];
        });
    });
}

- (void)showResults:(NSArray<SeekItem *> *)items query:(NSString *)q ms:(double)ms {
    _results = items;
    _lastQuery = q;
    _count.stringValue = [NSString stringWithFormat:@"%lu result%@ · %.0f ms", (unsigned long)items.count,
                                                    items.count == 1 ? @"" : @"s", ms];
    [_table reloadData];
    if (items.count > 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
    [self layoutForResults];
}

- (void)layoutChips {
    CGFloat x = 20;
    for (SeekChip *c in _chips) {
        c.frame = NSMakeRect(x, (kChipsHeight - 26) / 2, c.frame.size.width, 26);
        x += c.frame.size.width + 8;
    }
    BOOL any = NO;
    for (SeekChip *c in _chips) any = any || c.selected > 0;
    _clearChip.hidden = !any;
    _clearChip.frame = NSMakeRect(kWidth - 20 - _clearChip.frame.size.width, (kChipsHeight - 26) / 2,
                                  _clearChip.frame.size.width, 26);
}

- (seek_filter)currentFilter {
    seek_filter f = {0};
    f.scope = (uint8_t)_chips[0].selected;
    f.kind = (uint8_t)_chips[1].selected;
    static const uint64_t sizes[] = {0, 1ull << 20, 10ull << 20, 100ull << 20, 1ull << 30};
    f.min_size = sizes[_chips[2].selected];
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDate *now = [NSDate date], *since = nil;
    switch (_chips[3].selected) {
        case 1: since = [cal startOfDayForDate:now]; break;
        case 2: since = [cal dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:now options:0]; break;
        case 3: since = [cal dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:now options:0]; break;
        case 4: since = [cal dateByAddingUnit:NSCalendarUnitYear value:-1 toDate:now options:0]; break;
    }
    f.modified_after = since ? (int64_t)since.timeIntervalSince1970 : 0;
    return f;
}

- (void)updateDetail {
    SeekItem *it = [self selectedItem];
    if (!it) return;
    BOOL same = [_detailPath isEqualToString:it.path];
    [_detail showItem:it icon:[self iconForItem:it]];
    if (same) {
        // Only the icon changed (a thumbnail arrived): keep the facts already loaded.
        [self applyDetailFacts:it];
        return;
    }
    _detailPath = it.path;
    [self loadFactsFor:it];
}

// Cached by path + modification time so arrowing back and forth is instant.
- (void)applyDetailFacts:(SeekItem *)it {
    NSDictionary *facts = _facts[[self factsKeyFor:it]];
    if (!facts) return;
    [_detail setExtras:facts[@"extras"]];
    if (facts[@"dup"]) [_detail setDuplicates:facts[@"dup"] found:[facts[@"found"] boolValue]];
}

- (NSString *)factsKeyFor:(SeekItem *)it {
    return [NSString stringWithFormat:@"%@|%.0f", it.path, it.modified.timeIntervalSince1970];
}

- (void)loadFactsFor:(SeekItem *)it {
    if (!_facts) _facts = [NSMutableDictionary dictionary];
    NSString *key = [self factsKeyFor:it];
    if (_facts[key]) {
        [self applyDetailFacts:it];
        return;
    }
    BOOL checkDup = !it.isDir && it.size > 0;
    if (checkDup) [_detail setDuplicates:@"Checking…" found:NO];

    // 1) type-specific facts
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *extras = ExtraDetails(it);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *f = [self->_facts[key] mutableCopy] ?: [NSMutableDictionary dictionary];
            f[@"extras"] = extras;
            self->_facts[key] = f;
            if ([self->_detailPath isEqualToString:it.path]) [self->_detail setExtras:extras];
        });
    });
    if (!checkDup) return;

    // 2) duplicates: same-size candidates from the index, confirmed by content hash
    seek_index *idx = _idx;
    dispatch_async(_searchQueue, ^{
        seek_result res[200];
        int n = seek_find_same_size(idx, it.size, res, 200);
        NSMutableArray<NSString *> *cands = [NSMutableArray array];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (int i = 0; i < n; i++) {
            NSString *p = [fm stringWithFileSystemRepresentation:res[i].path length:strlen(res[i].path)];
            if (p && ![p isEqualToString:it.path]) [cands addObject:p];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSMutableArray<NSString *> *copies = [NSMutableArray array];
            BOOL tooBig = it.size > (2ull << 30);
            if (!tooBig && cands.count > 0) {
                NSData *headA = FileDigest(it.path, 65536), *fullA = nil;
                for (NSString *c in cands) {
                    if (![FileDigest(c, 65536) isEqualToData:headA]) continue;
                    if (!fullA) fullA = FileDigest(it.path, 0);
                    if ([FileDigest(c, 0) isEqualToData:fullA]) [copies addObject:c];
                }
            }
            NSString *text;
            if (tooBig) text = @"Too large to check";
            else if (copies.count == 0) text = @"None";
            else {
                NSString *where = copies[0].stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath.lastPathComponent;
                text = copies.count == 1 ? [NSString stringWithFormat:@"1 other copy · %@", where]
                                         : [NSString stringWithFormat:@"%lu other copies", (unsigned long)copies.count];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableDictionary *f = [self->_facts[key] mutableCopy] ?: [NSMutableDictionary dictionary];
                f[@"dup"] = text;
                f[@"found"] = @(copies.count > 0);
                self->_facts[key] = f;
                if ([self->_detailPath isEqualToString:it.path]) [self->_detail setDuplicates:text found:copies.count > 0];
            });
        });
    });
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    [self updateDetail];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_results.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    return [SeekRowView new];
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    SeekCell *cell = [tv makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [[SeekCell alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kRowHeight)];
        cell.identifier = @"cell";
    }
    SeekItem *it = _results[(NSUInteger)row];
    cell.name = it.name;
    cell.highlights = HighlightRanges(it.name, _lastQuery);
    cell.subtitle.stringValue = it.path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath;
    NSString *when = [_relDate localizedStringForDate:it.modified relativeToDate:[NSDate date]];
    cell.meta.stringValue = it.isDir
        ? [NSString stringWithFormat:@"Folder · %@", when]
        : [NSString stringWithFormat:@"%@ · %@",
              [NSByteCountFormatter stringFromByteCount:(long long)it.size
                                             countStyle:NSByteCountFormatterCountStyleFile], when];
    cell.imageView.image = [self iconForItem:it];
    [cell refreshColors];
    return cell;
}

// Folders and apps use their system icons (per path: apps have their own). Photos get a real thumbnail,
// generated in the background and swapped in when ready. Every other file gets a coloured badge for
// its type, cached per extension, so the list never touches the disk for icons.
- (NSImage *)iconForItem:(SeekItem *)it {
    NSString *ext = it.path.pathExtension.lowercaseString;
    if (it.isDir || [ext isEqualToString:@"app"]) {
        NSImage *img = [_icons objectForKey:it.path];
        if (!img) {
            img = [[NSWorkspace.sharedWorkspace iconForFile:it.path] copy];
            img.size = NSMakeSize(64, 64);
            [_icons setObject:img forKey:it.path];
        }
        return img;
    }
    if (HasThumbnail(ext)) {
        NSImage *thumb = [_icons objectForKey:it.path];
        if (thumb) return thumb;
        [self requestThumbnailFor:it.path];
    }
    NSString *key = [@"badge:" stringByAppendingString:ext];
    NSImage *badge = [_icons objectForKey:key];
    if (!badge) {
        badge = BadgeIcon(ext);
        [_icons setObject:badge forKey:key];
    }
    return badge;
}

- (void)requestThumbnailFor:(NSString *)path {
    if (!_thumbsPending) _thumbsPending = [NSMutableSet set];
    if ([_thumbsPending containsObject:path]) return;
    [_thumbsPending addObject:path];
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 2;
    QLThumbnailGenerationRequest *req =
        [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:path]
                                                           size:CGSizeMake(64, 64)
                                                          scale:scale
                                            representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    [QLThumbnailGenerator.sharedGenerator
        generateBestRepresentationForRequest:req
                           completionHandler:^(QLThumbnailRepresentation *rep, NSError *err) {
            NSImage *src = rep.NSImage;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!src) return; // keep the badge
                NSSize sz = src.size;
                NSImage *rounded = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect r) {
                    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6] addClip];
                    [src drawInRect:r];
                    return YES;
                }];
                [self->_icons setObject:rounded forKey:path];
                [self->_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self->_results.count)]
                                        columnIndexes:[NSIndexSet indexSetWithIndex:0]];
                [self updateDetail];
            });
        }];
}

// ---------------------------------------------------------------- keys & actions

- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)cmd {
    if (cmd == @selector(moveDown:)) { [self moveSelection:1]; return YES; }
    if (cmd == @selector(moveUp:)) { [self moveSelection:-1]; return YES; }
    if (cmd == @selector(scrollPageDown:) || cmd == @selector(pageDown:)) { [self moveSelection:kVisibleRows]; return YES; }
    if (cmd == @selector(scrollPageUp:) || cmd == @selector(pageUp:)) { [self moveSelection:-kVisibleRows]; return YES; }
    if (cmd == @selector(insertNewline:)) { [self openSelected]; return YES; }
    if (cmd == @selector(cancelOperation:)) {
        if (_field.stringValue.length > 0) {
            _field.stringValue = @"";
            [self runQuery:@""];
        } else {
            [self hidePanel];
        }
        return YES;
    }
    return NO;
}

// Command-key shortcuts that the field editor would otherwise swallow.
- (BOOL)panelHandleKeyDown:(NSEvent *)e {
    NSEventModifierFlags mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods != NSEventModifierFlagCommand) return NO;
    if (e.keyCode == kVK_Return || e.keyCode == kVK_ANSI_KeypadEnter) {
        [self revealSelected];
        return YES;
    }
    if ([e.charactersIgnoringModifiers isEqualToString:@"c"]) {
        NSText *editor = [_panel fieldEditor:NO forObject:_field];
        if (editor && editor.selectedRange.length > 0) return NO; // normal copy of the typed text
        return [self copySelectedPath];
    }
    return NO;
}

- (void)moveSelection:(NSInteger)delta {
    NSInteger count = (NSInteger)_results.count;
    if (count == 0) return;
    NSInteger row = _table.selectedRow;
    row = row < 0 ? 0 : MAX(0, MIN(count - 1, row + delta));
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_table scrollRowToVisible:row];
}

- (SeekItem *)selectedItem {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_results.count) return nil;
    return _results[(NSUInteger)row];
}

- (void)openSelected {
    SeekItem *it = [self selectedItem];
    if (!it) return;
    [self hidePanel];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:it.path isDirectory:it.isDir]];
}

- (void)revealSelected {
    SeekItem *it = [self selectedItem];
    if (!it) return;
    [self hidePanel];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:it.path] ]];
}

- (void)copyPathAction {
    [self copySelectedPath];
}

- (BOOL)copySelectedPath {
    SeekItem *it = [self selectedItem];
    if (!it) return NO;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:it.path forType:NSPasteboardTypeString];
    _status.stringValue = @"Path copied";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateStatus];
    });
    return YES;
}

// ---------------------------------------------------------------- indexing

// All index work runs on the serial _indexQueue so the main thread never waits on the core.
- (void)reindexAll {
    if (_pendingJobs > 0) return; // a pass is already running or queued
    [self enqueueIndexJob:^(seek_index *idx, void *ctx) {
        seek_reindex_all(idx, OnIndexProgress, ctx);
    }];
}

- (void)indexFolder:(NSString *)path {
    const char *p = strdup(path.fileSystemRepresentation);
    [self enqueueIndexJob:^(seek_index *idx, void *ctx) {
        seek_add_root(idx, p);
        seek_index_root(idx, p, OnIndexProgress, ctx);
        free((void *)p);
    }];
}

- (void)enqueueIndexJob:(void (^)(seek_index *idx, void *ctx))job {
    _pendingJobs++;
    _indexing = YES;
    _indexSeen = 0;
    [self updateStatus];
    seek_index *idx = _idx;
    void *ctx = (__bridge void *)self;
    dispatch_async(_indexQueue, ^{
        job(idx, ctx);
        dispatch_async(dispatch_get_main_queue(), ^{ [self indexingFinished]; });
    });
}

- (void)indexingFinished {
    _pendingJobs--;
    _indexing = _pendingJobs > 0;
    [self updateStatus];
    if (!_indexing) {
        [_settings refresh];
        [_onboarding finished];
    }
    if (_panel.isVisible && _lastQuery.length > 0) [self runQuery:_lastQuery]; // refresh with new files
}

- (void)indexProgress:(uint64_t)seen {
    _indexSeen = seen;
    [_onboarding progress:seen];
    [self updateStatus];
}

- (void)updateStatus {
    NSString *s = _indexing
        ? [NSString stringWithFormat:@"Indexing… %@", FormatCount(_indexSeen)]
        : [NSString stringWithFormat:@"%@ items", FormatCount(seek_file_count(_idx))];
    _status.stringValue = _indexing ? s : [@"Index up to date · " stringByAppendingString:s];
    _dot.layer.backgroundColor = (_indexing ? NSColor.systemOrangeColor : NSColor.systemGreenColor).CGColor;
    _statusMenuLine.title = s;
    _statusLine = s;
    [_settings statusChanged];
}

- (void)showOnboarding {
    if (!_onboarding) _onboarding = [[SeekOnboarding alloc] initWithHost:self];
    [self hidePanel];
    [NSApp activateIgnoringOtherApps:YES];
    [_onboarding show];
}

// ---- SeekOnboardingHost
- (void)startOnboardingIndexing:(NSArray<NSString *> *)paths {
    [self enqueueIndexJob:^(seek_index *idx, void *ctx) {
        for (NSUInteger i = 0; i < paths.count; i++) {
            const char *p = paths[i].fileSystemRepresentation;
            dispatch_async(dispatch_get_main_queue(), ^{ [self->_onboarding folderStarted:i]; });
            seek_add_root(idx, p);
            int64_t n = seek_index_root(idx, p, OnIndexProgress, ctx);
            dispatch_async(dispatch_get_main_queue(), ^{ [self->_onboarding folderDone:i files:n < 0 ? 0 : (uint64_t)n]; });
        }
    }];
}

- (void)openSettingsFromOnboarding { [self showSettings]; }
- (BOOL)menuBarIconVisible { return _statusItem.visible; }
- (void)setMenuBarIconVisible:(BOOL)visible {
    _statusItem.visible = visible;
    [NSUserDefaults.standardUserDefaults setBool:!visible forKey:@"hideMenuBarIcon"];
}

// Opening the app again (Finder, Spotlight) brings the icon back and shows Settings.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    if (!_statusItem.visible) [self setMenuBarIconVisible:YES];
    [self showSettings];
    return NO;
}

- (void)showSettings {
    if (!_settings) _settings = [[SeekSettings alloc] initWithHost:self];
    [self hidePanel];
    [NSApp activateIgnoringOtherApps:YES];
    [_settings show];
}

// ---- SeekSettingsHost
- (seek_index *)settingsIndex { return _idx; }
- (NSString *)settingsStatusLine { return _statusLine; }
- (BOOL)settingsIsIndexing { return _indexing; }
- (BOOL)settingsLoginEnabled { return SMAppService.mainAppService.status == SMAppServiceStatusEnabled; }

- (void)removeFolder:(NSString *)path {
    const char *p = strdup(path.fileSystemRepresentation);
    [self enqueueIndexJob:^(seek_index *idx, void *ctx) {
        seek_remove_root(idx, p);
        free((void *)p);
    }];
}

// Exclusions apply on the next scan, so changing one rescans right away.
- (void)addExclude:(NSString *)pattern {
    const char *p = strdup(pattern.UTF8String);
    [self enqueueIndexJob:^(seek_index *idx, void *ctx) {
        seek_add_exclude(idx, p);
        free((void *)p);
        seek_reindex_all(idx, OnIndexProgress, ctx);
    }];
}

- (void)removeExclude:(NSString *)pattern {
    const char *p = strdup(pattern.UTF8String);
    [self enqueueIndexJob:^(seek_index *idx, void *ctx) {
        seek_remove_exclude(idx, p);
        free((void *)p);
        seek_reindex_all(idx, OnIndexProgress, ctx);
    }];
}

- (void)showDuplicates {
    if (!_duplicatesWindow) _duplicatesWindow = BuildDuplicatesWindow();
    [self showWindow:_duplicatesWindow];
}

- (void)showWindow:(NSWindow *)w {
    [self hidePanel];
    [NSApp activateIgnoringOtherApps:YES];
    [w makeKeyAndOrderFront:nil];
}

- (void)chooseFolder {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseDirectories = YES;
    op.canChooseFiles = NO;
    op.allowsMultipleSelection = NO;
    op.prompt = @"Index";
    op.message = @"Choose a folder for Seek to index";
    [NSApp activateIgnoringOtherApps:YES];
    if ([op runModal] == NSModalResponseOK && op.URL) [self indexFolder:op.URL.path];
}

- (void)toggleLogin {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    BOOL on = svc.status == SMAppServiceStatusEnabled;
    if (on) [svc unregisterAndReturnError:&err];
    else [svc registerAndReturnError:&err];
    if (err) NSLog(@"Seek: launch at login: %@", err);
    _loginItem.state = svc.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

@end

// ------------------------------------------------------------------ C callbacks

static void OnIndexProgress(void *ctx, uint64_t seen) {
    AppDelegate *app = (__bridge AppDelegate *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ [app indexProgress:seen]; });
}

static OSStatus OnHotKey(EventHandlerCallRef next, EventRef event, void *userData) {
    AppDelegate *app = (__bridge AppDelegate *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{ [app togglePanel]; });
    return noErr;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory; // menu bar only, no Dock icon
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
