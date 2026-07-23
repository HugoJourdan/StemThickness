//
//  StemThickness.m
//  StemThickness
//
//  Created by Georg Seifert on 20.03.21.
//Copyright © 2021 RafalBuchner. All rights reserved.
//

#import "StemThickness.h"
#import <GlyphsCore/GlyphsFilterProtocol.h>
#import <GlyphsCore/GSGlyphEditViewProtocol.h>
#import <GlyphsCore/GSFilterPlugin.h>
#import <GlyphsCore/GSGlyph.h>
#import <GlyphsCore/GSLayer.h>
#import <GlyphsCore/GSFont.h>
#import <GlyphsCore/GSPath.h>
#import <GlyphsCore/GSFontMaster.h>
#import <GlyphsCore/GSComponent.h>
#import <GlyphsCore/GSProxyShapes.h>
#import <GlyphsCore/GSCallbackHandler.h>

NSPoint GSMiddlePointStem(NSPoint A, NSPoint B) {
	A.x = (A.x + B.x) * 0.5;
	A.y = (A.y + B.y) * 0.5;
	return A;
}

/*
 Glyphs 4 changed -[GSLayer calculateIntersections…] to return a private FTPointArray
 instead of an NSArray<NSValue*>. FTPointArray responds to -count / -pointAtIndex: but is
 NOT NSFastEnumeration and its elements are raw NSPoints, not NSValues — so the old
 `for (NSValue *v in crossPoints)` / `crossPoints[i]` iteration silently broke under G4.
 Normalize whatever the running Glyphs returns to a plain NSArray<NSValue*>.
 */
@protocol GSPointArrayCompat <NSObject>
- (NSUInteger)count;
- (NSPoint)pointAtIndex:(NSUInteger)index;
@end

static NSArray<NSValue *> *normalizeIntersections(id result) {
	if (!result || [result isKindOfClass:[NSArray class]]) {
		return result ?: @[];  // Glyphs 3: already NSArray<NSValue*>.
	}
	if ([result respondsToSelector:@selector(pointAtIndex:)]) {  // Glyphs 4: FTPointArray.
		id <GSPointArrayCompat> points = result;
		NSUInteger count = [points count];
		NSMutableArray<NSValue *> *values = [NSMutableArray arrayWithCapacity:count];
		for (NSUInteger i = 0; i < count; i++) {
			[values addObject:@([points pointAtIndex:i])];
		}
		return values;
	}
	return @[];  // Unknown container shape: fail safe rather than crash the host.
}

NSString *formatDistance(CGFloat d, CGFloat scale) {
	// calculates how value of thickness will be shown
	if (scale < 2) {
		return [NSString stringWithFormat:@"%d", (int)round(d)];
		// return "%i." % round(d) // use this instead if you really want the dot at the end, but I don't understand why --mekkablue
	}
	else if (scale < 3) {
		return [NSString stringWithFormat:@"%0.1f", d];
	}
	else if (scale < 10) {
		return [NSString stringWithFormat:@"%0.2f", d];
	}
	return [NSString stringWithFormat:@"%0.3f", d];
}

static NSColor *red = nil;
static NSColor *blue = nil;
static NSColor *pointColor = nil;

@implementation StemThickness {
	NSViewController <GSGlyphEditViewControllerProtocol> *_editViewController;
	id _lastNodePair;
	CGFloat _scale;
	NSPoint _layerOrigin;
}

+ (void)initialize {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		red  = [NSColor colorWithCalibratedRed:0.96 green:0.44 blue:0.44 alpha:1];
		blue = [NSColor colorWithCalibratedRed:0.65 green:0.63 blue:0.94 alpha:1];
		pointColor = [NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.6 alpha:0.7];
	});
}

- (instancetype)init {
	self = [super init];
	if (self) {
		// do stuff
	}
	return self;
}

- (NSUInteger)interfaceVersion {
	// Distinguishes the API verison the plugin was built for. Return 1.
	return 1;
}

- (NSString *)title {
	return NSLocalizedStringFromTableInBundle(@"Stem Thickness", nil, [NSBundle bundleForClass:[self class]], @"");
}

- (NSString *)keyEquivalent {
	return @"s";
}

- (NSEventModifierFlags)modifierMask {
	return NSEventModifierFlagControl;
}

- (void)drawForegroundWithOptions:(NSDictionary *)options {
	NSView <GSGlyphEditViewProtocol> *view = _editViewController.graphicView;
	_scale = view.scale; // scale of edit window
	GSFont *font = [_editViewController representedObject];
	CGFloat upm = font.unitsPerEm;
	if (_scale < 0.15 * 1000 / upm || _scale > 6.0 * 1000 / upm) {
		return;
	}
	NSPoint crossHairCenter = [view getActiveLocation:[NSApp currentEvent]];
	_layerOrigin = view.activePosition;

	GSLayer *layer = [view activeLayer];
	NSDictionary *closestData = [self calcClosestInfo:layer position:crossHairCenter];
	if (!closestData) {
		return;
	}
	GSLog(@"closestData %@", closestData);
	if (GSDistance(crossHairCenter, [closestData[@"onCurve"] pointValue]) > 35 / _scale) {
		_lastNodePair = nil;
		return;
	}
	[self drawCrossingsForData:closestData];
}

- (CGFloat)getHandleSize {
	/*
	 Returns the current handle size as set in user preferences.
	 */
	NSUInteger Selected = [NSUserDefaults.standardUserDefaults integerForKey:@"GSHandleSize"];
	if (Selected == 0) {
		return 5.0;
	}
	else if (Selected == 2) {
		return 10.0;
	}
	else {
		return 7.0;  // Regular
	}
}

- (void)drawPoint:(NSPoint)thisPoint size:(CGFloat)size color:(NSColor *)color {

	if (!color) {
		color = pointColor;
	}
	// from Show Angled Handles by MekkaBlue
	@try {
		[color set];
		NSRect myRect = NSMakeRect(thisPoint.x - size * 0.5, thisPoint.y - size * 0.5, size, size);
		NSBezierPath *seledinCircles = [NSBezierPath bezierPathWithOvalInRect:myRect];
		[seledinCircles fill];
	}
	@catch (NSException *exception) {
		NSLog(@"__drawPoint %@", exception);
	}
}

- (void)drawDashedStrokeA:(NSPoint)A b:(NSPoint)B {
	NSBezierPath *bez = [NSBezierPath bezierPath];
	bez.lineWidth = 0;
	CGFloat dash[] = {5.0, 3.0};
	[bez setLineDash:dash count:2 phase:0];
	[bez moveToPoint:A];
	[bez lineToPoint:B];
	[bez stroke];
}

- (void)drawCrossingsForData:(NSDictionary *)closestData {
	CGFloat HandleSize = [self getHandleSize];

	CGFloat zoomedHandleSize = HandleSize * 0.875;

	GSLayer *layer = closestData[@"layer"];
	NSPoint closestPoint = [closestData[@"onCurve"] pointValue];


	// returns list of intersections. The bare `…decompose:` selector was dropped from the
	// Glyphs headers; use the explicit 5-arg variant (present in G3 + G4) and normalize the
	// return value, which is NSArray<NSValue*> in G3 but FTPointArray in G4.
	NSArray<NSValue *> *crossPoints = normalizeIntersections([layer calculateIntersectionsStartPoint:[closestData[@"normal"] pointValue] endPoint:[closestData[@"minusNormal"] pointValue] decompose:NO ignoreLocked:NO clipToBound:NO]);

	if (crossPoints.count > 2) {
		// find closest point in the list of intersections
		// the point before and after that point is what we are looking for
		NSInteger closestI = -1;
		CGFloat closestDistance = 1000000;
		NSInteger i = 0;
		for (NSValue *crossValue in crossPoints) {
			NSPoint cross = [crossValue pointValue];
			CGFloat dist = GSDistance(cross, closestPoint);
			if (dist < closestDistance) {
				closestDistance = dist;
				closestI = i;
			}
			i++;
		}
		if (closestI < 1) {
			return;
		}
		i = closestI;
		NSInteger n = i - 1;
		if (i < crossPoints.count) {
			i++;
		}
		@try {
			NSPoint FirstCrossPointA = [crossPoints[i] pointValue];	// blue
			CGFloat FirstDistance  = GSDistance(closestPoint, FirstCrossPointA);
			NSPoint FirstCrossPointB = [crossPoints[n] pointValue];	// red
			CGFloat SecondDistance = GSDistance(closestPoint, FirstCrossPointB);

			closestPoint = GSScalePoint(closestPoint, _scale);
			closestPoint = GSAddPoints(closestPoint, _layerOrigin);
			FirstCrossPointA = GSScalePoint(FirstCrossPointA, _scale);
			FirstCrossPointA = GSAddPoints(FirstCrossPointA, _layerOrigin);
			FirstCrossPointB = GSScalePoint(FirstCrossPointB, _scale);
			FirstCrossPointB = GSAddPoints(FirstCrossPointB, _layerOrigin);

			[self drawPoint:closestPoint size:zoomedHandleSize color:nil];

			BOOL firstDraws = NO;
			if (0.01 < FirstDistance && FirstDistance < 1199) {
				firstDraws = YES;
				[self showDistance:FirstDistance cross:FirstCrossPointA onCurve:closestPoint color:blue];
			}
			if (0.01 < SecondDistance && SecondDistance < 1199) {
				NSColor *secondColor = firstDraws ? red : blue;
				[self showDistance:SecondDistance cross:FirstCrossPointB onCurve:closestPoint color:secondColor];
			}
		}
		@catch (NSException *exception) {
			NSLog(@"!!drawCrossingsForData %@", exception);
		}
	}
}

// Draws the measurement pill: a saturated accent-colored rounded rect with white text,
// self-drawn with plain AppKit. Glyphs 4 dropped NSString+BadgeDrawing.h and its runtime
// -drawBadgeAtPoint:… renders a washed-out light badge with dark text instead of the G3
// look, so we render the pill ourselves to stay identical across both hosts.
- (void)drawBadge:(NSString *)text center:(NSPoint)center fontSize:(CGFloat)fontSize color:(NSColor *)color {
	// Smaller and more muted than the G3 badge: shrink the text and render the pill
	// semi-transparent so the number reads without dominating the outline.
	fontSize *= 0.8;
	NSDictionary *attrs = @{
		NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightRegular],
		NSForegroundColorAttributeName: [NSColor.whiteColor colorWithAlphaComponent:0.9],
	};
	NSSize textSize = [text sizeWithAttributes:attrs];
	CGFloat padX = fontSize * 0.45;
	CGFloat padY = fontSize * 0.18;
	NSRect box = NSMakeRect(center.x - textSize.width * 0.5 - padX,
							center.y - textSize.height * 0.5 - padY,
							textSize.width + padX * 2,
							textSize.height + padY * 2);
	CGFloat radius = NSHeight(box) * 0.4;
	[[color colorWithAlphaComponent:0.5] set];
	[[NSBezierPath bezierPathWithRoundedRect:box xRadius:radius yRadius:radius] fill];
	[text drawAtPoint:NSMakePoint(center.x - textSize.width * 0.5, center.y - textSize.height * 0.5) withAttributes:attrs];
}

- (void)showDistance:(CGFloat)d cross:(NSPoint)cross onCurve:(NSPoint)onCurve color:(NSColor *)color {
	// self.lastNodePair = (cross, onCurve) //TODO

	CGFloat handleSize = [self getHandleSize];
	CGFloat zoomedHandleSize = handleSize * 0.875 * 0.75;
	NSString *distanceShowed = formatDistance(d, _scale);
	NSPoint thisDistanceCenter = GSMiddlePointStem(onCurve, cross);
	[color set];
	[self drawDashedStrokeA:onCurve b:cross];
	CGFloat fontSize = handleSize * 1.5 * pow(_scale, 0.1);
	[self drawBadge:distanceShowed center:thisDistanceCenter fontSize:fontSize color:color];
	[self drawPoint:cross size:zoomedHandleSize color:color];
}

- (void)mouseMoved:(NSNotification *)notification {
	[_editViewController redraw];
}

- (void)willActivate {
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mouseMoved:) name:@"mouseMovedNotification" object:nil];
}

- (void)willDeactivate {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSDictionary *)calcClosestInfo:(GSLayer *)layer position:(NSPoint)pt {
	@try {
		NSPoint closestPoint = NSZeroPoint;
		CGFloat dist = 100000.0;
		for (GSPath *path in layer.paths) {
			CGFloat currPathTime;
			NSPoint currClosestPoint = [path nearestPointOnPath:pt pathTime:&currPathTime];
			CGFloat currDist = GSDistance(currClosestPoint, pt);
			if (currDist < dist) {
				dist = currDist;
				closestPoint = currClosestPoint;
			}
		}
		if (dist > 99999.0) {
			return nil;
		}
		NSPoint direction = GSUnitVectorFromTo(pt, closestPoint);
		NSPoint closestPointNormal = GSAddPoints(pt, GSScalePoint(direction, 10000));
		NSPoint minusClosestPointNormal = GSAddPoints(pt, GSScalePoint(direction, -10000));
		return @{
			@"onCurve": @(closestPoint),
			@"normal": @(closestPointNormal),
			@"minusNormal": @(minusClosestPointNormal),
			@"layer": layer,
		};
	}
	@catch (NSException *exception) {
		NSLog(@"__calcClosestInfo: %@", exception);
	}
	return nil;
}

- (NSViewController <GSGlyphEditViewControllerProtocol>*)controller {
	return _editViewController;
}

- (void)setController:(NSViewController <GSGlyphEditViewControllerProtocol>*)Controller {
	// Use [self controller]; as object for the current view controller.
	_editViewController = Controller;
}

@end
