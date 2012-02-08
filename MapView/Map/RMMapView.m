//
//  RMMapView.m
//
// Copyright (c) 2008-2009, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "RMMapView.h"
#import "RMMapViewDelegate.h"
#import "RMPixel.h"

#import "RMFoundation.h"
#import "RMProjection.h"
#import "RMMarker.h"
#import "RMPath.h"
#import "RMAnnotation.h"
#import "RMQuadTree.h"

#import "RMFractalTileProjection.h"
#import "RMOpenStreetMapSource.h"

#import "RMTileCache.h"
#import "RMTileSource.h"

#import "RMScrollView.h"
#import "RMMapTiledLayerView.h"
#import "RMMapOverlayView.h"

#pragma mark --- begin constants ----

#define kiPhoneMilimeteresPerPixel .1543
#define kZoomRectPixelBuffer 100.0

#define kDefaultInitialLatitude 47.56
#define kDefaultInitialLongitude 10.22

#define kDefaultMinimumZoomLevel 0.0
#define kDefaultMaximumZoomLevel 25.0
#define kDefaultInitialZoomLevel 13.0

#pragma mark --- end constants ----

@interface RMMapView (PrivateMethods)

@property (nonatomic, retain) RMMapLayer *overlay;

- (void)createMapView;

- (void)correctPositionOfAllAnnotations;
- (void)correctPositionOfAllAnnotationsIncludingInvisibles:(BOOL)correctAllLayers wasZoom:(BOOL)wasZoom;

@end

#pragma mark -

@implementation RMMapView
{
    BOOL _delegateHasBeforeMapMove;
    BOOL _delegateHasAfterMapMove;
    BOOL _delegateHasBeforeMapZoom;
    BOOL _delegateHasAfterMapZoom;
    BOOL _delegateHasMapViewRegionDidChange;
    BOOL _delegateHasDoubleTapOnMap;
    BOOL _delegateHasDoubleTapTwoFingersOnMap;
    BOOL _delegateHasSingleTapOnMap;
    BOOL _delegateHasSingleTapTwoFingersOnMap;
    BOOL _delegateHasLongSingleTapOnMap;
    BOOL _delegateHasTapOnAnnotation;
    BOOL _delegateHasDoubleTapOnAnnotation;
    BOOL _delegateHasTapOnLabelForAnnotation;
    BOOL _delegateHasDoubleTapOnLabelForAnnotation;
    BOOL _delegateHasShouldDragMarker;
    BOOL _delegateHasDidDragMarker;
    BOOL _delegateHasDidEndDragMarker;
    BOOL _delegateHasLayerForAnnotation;
    BOOL _delegateHasWillHideLayerForAnnotation;
    BOOL _delegateHasDidHideLayerForAnnotation;

    BOOL _constrainMovement;
    RMProjectedPoint _northEastConstraint, _southWestConstraint;

    float _lastZoom;
    CGPoint _lastContentOffset, _accumulatedDelta;
    BOOL _mapScrollViewIsZooming;
}

@synthesize decelerationMode;

@synthesize boundingMask;
@synthesize minZoom, maxZoom;
@synthesize screenScale;
@synthesize tileCache;
@synthesize quadTree;
@synthesize enableClustering, positionClusterMarkersAtTheGravityCenter, clusterMarkerSize;
@synthesize adjustTilesForRetinaDisplay;

#pragma mark -
#pragma mark Initialization

- (void)performInitializationWithTilesource:(id <RMTileSource>)newTilesource
                           centerCoordinate:(CLLocationCoordinate2D)initialCenterCoordinate
                                  zoomLevel:(float)initialZoomLevel
                               maxZoomLevel:(float)maxZoomLevel
                               minZoomLevel:(float)minZoomLevel
                            backgroundImage:(UIImage *)backgroundImage
{
	_constrainMovement = NO;

    self.backgroundColor = [UIColor grayColor];

    tileSource = nil;
    projection = nil;
    mercatorToTileProjection = nil;
    mapScrollView = nil;
    tiledLayerView = nil;
    overlayView = nil;

    screenScale = 1.0;
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)])
    {
        screenScale = [[[UIScreen mainScreen] valueForKey:@"scale"] floatValue];
    }

    boundingMask = RMMapMinWidthBound;
    adjustTilesForRetinaDisplay = NO;

    annotations = [NSMutableArray new];
    visibleAnnotations = [NSMutableSet new];
    [self setQuadTree:[[[RMQuadTree alloc] initWithMapView:self] autorelease]];
    enableClustering = positionClusterMarkersAtTheGravityCenter = NO;
    clusterMarkerSize = CGSizeMake(100.0, 100.0);

    [self setTileCache:[[[RMTileCache alloc] init] autorelease]];
    [self setTileSource:newTilesource];

    [self setBackgroundView:[[[UIView alloc] initWithFrame:[self bounds]] autorelease]];
    if (backgroundImage)
        self.backgroundView.layer.contents = (id)backgroundImage.CGImage;

    if (minZoomLevel < newTilesource.minZoom) minZoomLevel = newTilesource.minZoom;
    if (maxZoomLevel > newTilesource.maxZoom) maxZoomLevel = newTilesource.maxZoom;
    [self setMinZoom:minZoomLevel];
    [self setMaxZoom:maxZoomLevel];
    [self setZoom:initialZoomLevel];

    [self createMapView];
    [self setCenterCoordinate:initialCenterCoordinate animated:NO];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMemoryWarningNotification:)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];

    RMLog(@"Map initialised. tileSource:%@, minZoom:%f, maxZoom:%f, zoom:%f at {%f,%f}", tileSource, [self minZoom], [self maxZoom], [self zoom], [self centerCoordinate].longitude, [self centerCoordinate].latitude);
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    LogMethod();

    if (!(self = [super initWithCoder:aDecoder]))
        return nil;

	CLLocationCoordinate2D coordinate;
	coordinate.latitude = kDefaultInitialLatitude;
	coordinate.longitude = kDefaultInitialLongitude;

    [self performInitializationWithTilesource:[[RMOpenStreetMapSource new] autorelease]
                             centerCoordinate:coordinate
                                    zoomLevel:kDefaultInitialZoomLevel
                                 maxZoomLevel:kDefaultMaximumZoomLevel
                                 minZoomLevel:kDefaultMinimumZoomLevel
                              backgroundImage:nil];

    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    LogMethod();

    return [self initWithFrame:frame andTilesource:[[RMOpenStreetMapSource new] autorelease]];
}

- (id)initWithFrame:(CGRect)frame andTilesource:(id <RMTileSource>)newTilesource
{
	LogMethod();

	CLLocationCoordinate2D coordinate;
	coordinate.latitude = kDefaultInitialLatitude;
	coordinate.longitude = kDefaultInitialLongitude;

	return [self initWithFrame:frame
                 andTilesource:newTilesource
              centerCoordinate:coordinate
                     zoomLevel:kDefaultInitialZoomLevel
                  maxZoomLevel:kDefaultMaximumZoomLevel
                  minZoomLevel:kDefaultMinimumZoomLevel
               backgroundImage:nil];
}

- (id)initWithFrame:(CGRect)frame
      andTilesource:(id <RMTileSource>)newTilesource
   centerCoordinate:(CLLocationCoordinate2D)initialCenterCoordinate
          zoomLevel:(float)initialZoomLevel
       maxZoomLevel:(float)maxZoomLevel
       minZoomLevel:(float)minZoomLevel
    backgroundImage:(UIImage *)backgroundImage
{
    LogMethod();

    if (!(self = [super initWithFrame:frame]))
        return nil;

    [self performInitializationWithTilesource:newTilesource
                             centerCoordinate:initialCenterCoordinate
                                    zoomLevel:initialZoomLevel
                                 maxZoomLevel:maxZoomLevel
                                 minZoomLevel:minZoomLevel
                              backgroundImage:backgroundImage];

    return self;
}

- (void)setFrame:(CGRect)frame
{
    CGRect r = self.frame;
    [super setFrame:frame];

    // only change if the frame changes and not during initialization
    if (!CGRectEqualToRect(r, frame))
    {
        CGRect bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
        backgroundView.frame = bounds;
        mapScrollView.frame = bounds;
        overlayView.frame = bounds;
        [self correctPositionOfAllAnnotations];
    }
}

- (void)dealloc
{
    LogMethod();

    [self setDelegate:nil];
    [self setBackgroundView:nil];
    [self setQuadTree:nil];
    [annotations release]; annotations = nil;
    [visibleAnnotations release]; visibleAnnotations = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [tiledLayerView release]; tiledLayerView = nil;
    [mapScrollView removeObserver:self forKeyPath:@"contentOffset"];
    [mapScrollView release]; mapScrollView = nil;
    [overlayView release]; overlayView = nil;
    [tileSource cancelAllDownloads]; [tileSource release]; tileSource = nil;
    [projection release]; projection = nil;
    [mercatorToTileProjection release]; mercatorToTileProjection = nil;
    [self setTileCache:nil];
    [super dealloc];
}

- (void)didReceiveMemoryWarning
{
    LogMethod();

    [tileSource didReceiveMemoryWarning];
    [tileCache didReceiveMemoryWarning];
}

- (void)handleMemoryWarningNotification:(NSNotification *)notification
{
	[self didReceiveMemoryWarning];
}

- (NSString *)description
{
	CGRect bounds = [self bounds];

	return [NSString stringWithFormat:@"MapView at %.0f,%.0f-%.0f,%.0f", bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height];
}

#pragma mark -
#pragma mark Delegate

@dynamic delegate;

- (void)setDelegate:(id <RMMapViewDelegate>)aDelegate
{
    if (delegate == aDelegate)
        return;

    delegate = aDelegate;

    _delegateHasBeforeMapMove = [delegate respondsToSelector:@selector(beforeMapMove:)];
    _delegateHasAfterMapMove  = [delegate respondsToSelector:@selector(afterMapMove:)];

    _delegateHasBeforeMapZoom = [delegate respondsToSelector:@selector(beforeMapZoom:)];
    _delegateHasAfterMapZoom  = [delegate respondsToSelector:@selector(afterMapZoom:)];

    _delegateHasMapViewRegionDidChange = [delegate respondsToSelector:@selector(mapViewRegionDidChange:)];

    _delegateHasDoubleTapOnMap = [delegate respondsToSelector:@selector(doubleTapOnMap:at:)];
    _delegateHasDoubleTapTwoFingersOnMap = [delegate respondsToSelector:@selector(doubleTapTwoFingersOnMap:at:)];
    _delegateHasSingleTapOnMap = [delegate respondsToSelector:@selector(singleTapOnMap:at:)];
    _delegateHasSingleTapTwoFingersOnMap = [delegate respondsToSelector:@selector(singleTapTwoFingersOnMap:at:)];
    _delegateHasLongSingleTapOnMap = [delegate respondsToSelector:@selector(longSingleTapOnMap:at:)];

    _delegateHasTapOnAnnotation = [delegate respondsToSelector:@selector(tapOnAnnotation:onMap:)];
    _delegateHasDoubleTapOnAnnotation = [delegate respondsToSelector:@selector(doubleTapOnAnnotation:onMap:)];
    _delegateHasTapOnLabelForAnnotation = [delegate respondsToSelector:@selector(tapOnLabelForAnnotation:onMap:)];
    _delegateHasDoubleTapOnLabelForAnnotation = [delegate respondsToSelector:@selector(doubleTapOnLabelForAnnotation:onMap:)];

    _delegateHasShouldDragMarker = [delegate respondsToSelector:@selector(mapView:shouldDragAnnotation:)];
    _delegateHasDidDragMarker = [delegate respondsToSelector:@selector(mapView:didDragAnnotation:withDelta:)];
    _delegateHasDidEndDragMarker = [delegate respondsToSelector:@selector(mapView:didEndDragAnnotation:)];

    _delegateHasLayerForAnnotation = [delegate respondsToSelector:@selector(mapView:layerForAnnotation:)];
    _delegateHasWillHideLayerForAnnotation = [delegate respondsToSelector:@selector(mapView:willHideLayerForAnnotation:)];
    _delegateHasDidHideLayerForAnnotation = [delegate respondsToSelector:@selector(mapView:didHideLayerForAnnotation:)];
}

- (id <RMMapViewDelegate>)delegate
{
	return delegate;
}

#pragma mark -
#pragma mark Bounds

- (BOOL)projectedBounds:(RMProjectedRect)bounds containsPoint:(RMProjectedPoint)point
{
    if (bounds.origin.x > point.x ||
        bounds.origin.x + bounds.size.width < point.x ||
        bounds.origin.y > point.y ||
        bounds.origin.y + bounds.size.height < point.y)
    {
        return NO;
    }

    return YES;
}

- (RMProjectedRect)projectedRectFromLatitudeLongitudeBounds:(RMSphericalTrapezium)bounds
{
    float pixelBuffer = kZoomRectPixelBuffer;
    CLLocationCoordinate2D southWest = bounds.southWest;
    CLLocationCoordinate2D northEast = bounds.northEast;
    CLLocationCoordinate2D midpoint = {
        .latitude = (northEast.latitude + southWest.latitude) / 2,
        .longitude = (northEast.longitude + southWest.longitude) / 2
    };

    RMProjectedPoint myOrigin = [projection coordinateToProjectedPoint:midpoint];
    RMProjectedPoint southWestPoint = [projection coordinateToProjectedPoint:southWest];
    RMProjectedPoint northEastPoint = [projection coordinateToProjectedPoint:northEast];
    RMProjectedPoint myPoint = {
        .x = northEastPoint.x - southWestPoint.x,
        .y = northEastPoint.y - southWestPoint.y
    };

    // Create the new zoom layout
    RMProjectedRect zoomRect;

    // Default is with scale = 2.0 * mercators/pixel
    zoomRect.size.width = self.bounds.size.width * 2.0;
    zoomRect.size.height = self.bounds.size.height * 2.0;

    if ((myPoint.x / self.bounds.size.width) < (myPoint.y / self.bounds.size.height))
    {
        if ((myPoint.y / (self.bounds.size.height - pixelBuffer)) > 1)
        {
            zoomRect.size.width = self.bounds.size.width * (myPoint.y / (self.bounds.size.height - pixelBuffer));
            zoomRect.size.height = self.bounds.size.height * (myPoint.y / (self.bounds.size.height - pixelBuffer));
        }
    }
    else
    {
        if ((myPoint.x / (self.bounds.size.width - pixelBuffer)) > 1)
        {
            zoomRect.size.width = self.bounds.size.width * (myPoint.x / (self.bounds.size.width - pixelBuffer));
            zoomRect.size.height = self.bounds.size.height * (myPoint.x / (self.bounds.size.width - pixelBuffer));
        }
    }

    myOrigin.x = myOrigin.x - (zoomRect.size.width / 2);
    myOrigin.y = myOrigin.y - (zoomRect.size.height / 2);

    RMLog(@"Origin is calculated at: %f, %f", [projection projectedPointToCoordinate:myOrigin].longitude, [projection projectedPointToCoordinate:myOrigin].latitude);

    zoomRect.origin = myOrigin;

//    RMLog(@"Origin: x=%f, y=%f, w=%f, h=%f", zoomRect.origin.easting, zoomRect.origin.northing, zoomRect.size.width, zoomRect.size.height);

    return zoomRect;
}

- (BOOL)tileSourceBoundsContainProjectedPoint:(RMProjectedPoint)point
{
    RMSphericalTrapezium bounds = [self.tileSource latitudeLongitudeBoundingBox];

    if (bounds.northEast.latitude == 90 && bounds.northEast.longitude == 180 &&
        bounds.southWest.latitude == -90 && bounds.southWest.longitude == -180)
    {
        return YES;
    }

    return [self projectedBounds:tileSourceProjectedBounds containsPoint:point];
}

- (BOOL)tileSourceBoundsContainScreenPoint:(CGPoint)pixelCoordinate
{
    RMProjectedPoint projectedPoint = [self pixelToProjectedPoint:pixelCoordinate];

    return [self tileSourceBoundsContainProjectedPoint:projectedPoint];
}

// ===

- (void)setConstraintsSouthWest:(CLLocationCoordinate2D)southWest northEeast:(CLLocationCoordinate2D)northEast
{
    RMProjectedPoint projectedSouthWest = [projection coordinateToProjectedPoint:southWest];
    RMProjectedPoint projectedNorthEast = [projection coordinateToProjectedPoint:northEast];

    [self setProjectedConstraintsSouthWest:projectedSouthWest northEast:projectedNorthEast];
}

- (void)setProjectedConstraintsSouthWest:(RMProjectedPoint)southWest northEast:(RMProjectedPoint)northEast
{
    _southWestConstraint = southWest;
    _northEastConstraint = northEast;
    _constrainMovement = YES;
}

#pragma mark -
#pragma mark Movement

- (CLLocationCoordinate2D)centerCoordinate
{
    return [projection projectedPointToCoordinate:[self centerProjectedPoint]];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate
{
    [self setCenterProjectedPoint:[projection coordinateToProjectedPoint:centerCoordinate]];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate animated:(BOOL)animated
{
    [self setCenterProjectedPoint:[projection coordinateToProjectedPoint:centerCoordinate] animated:animated];
}

// ===

- (RMProjectedPoint)centerProjectedPoint
{
    CGPoint center = CGPointMake(mapScrollView.contentOffset.x + mapScrollView.bounds.size.width/2.0, mapScrollView.contentSize.height - (mapScrollView.contentOffset.y + mapScrollView.bounds.size.height/2.0));

    RMProjectedRect planetBounds = projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
    normalizedProjectedPoint.x = (center.x * self.metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedPoint.y = (center.y * self.metersPerPixel) - fabs(planetBounds.origin.y);

//    RMLog(@"centerProjectedPoint: {%f,%f}", normalizedProjectedPoint.x, normalizedProjectedPoint.y);

    return normalizedProjectedPoint;
}

- (void)setCenterProjectedPoint:(RMProjectedPoint)centerProjectedPoint
{
    [self setCenterProjectedPoint:centerProjectedPoint animated:YES];
}

- (void)setCenterProjectedPoint:(RMProjectedPoint)centerProjectedPoint animated:(BOOL)animated
{
    if (![self tileSourceBoundsContainProjectedPoint:centerProjectedPoint])
        return;

    if (_delegateHasBeforeMapMove)
        [delegate beforeMapMove:self];

//    RMLog(@"Current contentSize: {%.0f,%.0f}, zoom: %f", mapScrollView.contentSize.width, mapScrollView.contentSize.height, self.zoom);

    RMProjectedRect planetBounds = projection.planetBounds;
	RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = centerProjectedPoint.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = centerProjectedPoint.y + fabs(planetBounds.origin.y);

    [mapScrollView setContentOffset:CGPointMake(normalizedProjectedPoint.x / self.metersPerPixel - mapScrollView.bounds.size.width/2.0,
                                                mapScrollView.contentSize.height - ((normalizedProjectedPoint.y / self.metersPerPixel) + mapScrollView.bounds.size.height/2.0))
                           animated:animated];

//    RMLog(@"setMapCenterProjectedPoint: {%f,%f} -> {%.0f,%.0f}", centerProjectedPoint.x, centerProjectedPoint.y, mapScrollView.contentOffset.x, mapScrollView.contentOffset.y);

    if (_delegateHasAfterMapMove)
        [delegate afterMapMove:self];

    [self correctPositionOfAllAnnotations];
}

// ===

- (void)moveBy:(CGSize)delta
{
    if (_constrainMovement)
    {
        // calculate new bounds after move
        RMProjectedRect pBounds = [self projectedBounds];
        RMProjectedSize XYDelta = [self viewSizeToProjectedSize:delta];
        CGSize sizeRatio = CGSizeMake(((delta.width == 0) ? 0 : XYDelta.width / delta.width),
                                      ((delta.height == 0) ? 0 : XYDelta.height / delta.height));
        RMProjectedRect newBounds = pBounds;

        // move the rect by delta
        newBounds.origin.x -= XYDelta.width;
        newBounds.origin.y -= XYDelta.height;

        // see if new bounds are within constrained bounds, and constrain if necessary
        BOOL constrained = NO;

        if (newBounds.origin.y < _southWestConstraint.y)
        {
            newBounds.origin.y = _southWestConstraint.y;
            constrained = YES;
        }
        if (newBounds.origin.y + newBounds.size.height > _northEastConstraint.y)
        {
            newBounds.origin.y = _northEastConstraint.y - newBounds.size.height;
            constrained = YES;
        }
        if (newBounds.origin.x < _southWestConstraint.x)
        {
            newBounds.origin.x = _southWestConstraint.x;
            constrained = YES;
        }
        if (newBounds.origin.x + newBounds.size.width > _northEastConstraint.x)
        {
            newBounds.origin.x = _northEastConstraint.x - newBounds.size.width;
            constrained = YES;
        }

        if (constrained)
        {
            // Adjust delta to match constraint
            XYDelta.height = pBounds.origin.y - newBounds.origin.y;
            XYDelta.width = pBounds.origin.x - newBounds.origin.x;
            delta = CGSizeMake(((sizeRatio.width == 0) ? 0 : XYDelta.width / sizeRatio.width),
                               ((sizeRatio.height == 0) ? 0 : XYDelta.height / sizeRatio.height));
        }
    }

    if (_delegateHasBeforeMapMove)
        [delegate beforeMapMove:self];

    CGPoint contentOffset = mapScrollView.contentOffset;
    contentOffset.x += delta.width;
    contentOffset.y += delta.height;
    mapScrollView.contentOffset = contentOffset;

    if (_delegateHasAfterMapMove)
        [delegate afterMapMove:self];
}

#pragma mark -
#pragma mark Zoom

- (RMProjectedRect)projectedBounds
{
    CGPoint bottomLeft = CGPointMake(mapScrollView.contentOffset.x, mapScrollView.contentSize.height - (mapScrollView.contentOffset.y + mapScrollView.bounds.size.height));

    RMProjectedRect planetBounds = projection.planetBounds;
    RMProjectedRect normalizedProjectedRect;
    normalizedProjectedRect.origin.x = (bottomLeft.x * self.metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedRect.origin.y = (bottomLeft.y * self.metersPerPixel) - fabs(planetBounds.origin.y);
    normalizedProjectedRect.size.width = mapScrollView.bounds.size.width * self.metersPerPixel;
    normalizedProjectedRect.size.height = mapScrollView.bounds.size.height * self.metersPerPixel;

    return normalizedProjectedRect;
}

- (void)setProjectedBounds:(RMProjectedRect)boundsRect
{
    [self setProjectedBounds:boundsRect animated:YES];
}

- (void)setProjectedBounds:(RMProjectedRect)boundsRect animated:(BOOL)animated
{
    RMProjectedRect planetBounds = projection.planetBounds;
	RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = boundsRect.origin.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = boundsRect.origin.y + fabs(planetBounds.origin.y);

    float zoomScale = mapScrollView.zoomScale;
    CGRect zoomRect = CGRectMake((normalizedProjectedPoint.x / self.metersPerPixel) / zoomScale,
                                 ((planetBounds.size.height - normalizedProjectedPoint.y - boundsRect.size.height) / self.metersPerPixel) / zoomScale,
                                 (boundsRect.size.width / self.metersPerPixel) / zoomScale,
                                 (boundsRect.size.height / self.metersPerPixel) / zoomScale);
    [mapScrollView zoomToRect:zoomRect animated:animated];
}

- (float)adjustedZoomForCurrentBoundingMask:(float)zoomFactor
{
    if (boundingMask == RMMapNoMinBound)
        return zoomFactor;

    double newMetersPerPixel = self.metersPerPixel / zoomFactor;

    RMProjectedRect mercatorBounds = [projection planetBounds];

    // Check for MinWidthBound
    if (boundingMask & RMMapMinWidthBound)
    {
        double newMapContentsWidth = mercatorBounds.size.width / newMetersPerPixel;
        double screenBoundsWidth = [self bounds].size.width;
        double mapContentWidth;

        if (newMapContentsWidth < screenBoundsWidth)
        {
            // Calculate new zoom facter so that it does not shrink the map any further.
            mapContentWidth = mercatorBounds.size.width / self.metersPerPixel;
            zoomFactor = screenBoundsWidth / mapContentWidth;
        }
    }

    // Check for MinHeightBound
    if (boundingMask & RMMapMinHeightBound)
    {
        double newMapContentsHeight = mercatorBounds.size.height / newMetersPerPixel;
        double screenBoundsHeight = [self bounds].size.height;
        double mapContentHeight;

        if (newMapContentsHeight < screenBoundsHeight)
        {
            // Calculate new zoom facter so that it does not shrink the map any further.
            mapContentHeight = mercatorBounds.size.height / self.metersPerPixel;
            zoomFactor = screenBoundsHeight / mapContentHeight;
        }
    }

    return zoomFactor;
}

- (BOOL)shouldZoomToTargetZoom:(float)targetZoom withZoomFactor:(float)zoomFactor
{
    // bools for syntactical sugar to understand the logic in the if statement below
    BOOL zoomAtMax = ([self zoom] == [self maxZoom]);
    BOOL zoomAtMin = ([self zoom] == [self minZoom]);
    BOOL zoomGreaterMin = ([self zoom] > [self minZoom]);
    BOOL zoomLessMax = ([self zoom] < [self maxZoom]);

    //zooming in zoomFactor > 1
    //zooming out zoomFactor < 1
    if ((zoomGreaterMin && zoomLessMax) || (zoomAtMax && zoomFactor<1) || (zoomAtMin && zoomFactor>1))
        return YES;
    else
        return NO;
}

- (void)zoomContentByFactor:(float)zoomFactor near:(CGPoint)pivot animated:(BOOL)animated
{
    if (![self tileSourceBoundsContainScreenPoint:pivot])
        return;

    zoomFactor = [self adjustedZoomForCurrentBoundingMask:zoomFactor];
    float zoomDelta = log2f(zoomFactor);
    float targetZoom = zoomDelta + [self zoom];

    if (targetZoom == [self zoom])
        return;

    // clamp zoom to remain below or equal to maxZoom after zoomAfter will be applied
    // Set targetZoom to maxZoom so the map zooms to its maximum
    if (targetZoom > [self maxZoom])
    {
        zoomFactor = exp2f([self maxZoom] - [self zoom]);
        targetZoom = [self maxZoom];
    }

    // clamp zoom to remain above or equal to minZoom after zoomAfter will be applied
    // Set targetZoom to minZoom so the map zooms to its maximum
    if (targetZoom < [self minZoom])
    {
        zoomFactor = 1/exp2f([self zoom] - [self minZoom]);
        targetZoom = [self minZoom];
    }

    if ([self shouldZoomToTargetZoom:targetZoom withZoomFactor:zoomFactor])
    {
        float zoomScale = mapScrollView.zoomScale;
        CGSize newZoomSize = CGSizeMake(mapScrollView.bounds.size.width / zoomFactor,
                                        mapScrollView.bounds.size.height / zoomFactor);
        CGFloat factorX = pivot.x / mapScrollView.bounds.size.width,
                factorY = pivot.y / mapScrollView.bounds.size.height;
        CGRect zoomRect = CGRectMake(((mapScrollView.contentOffset.x + pivot.x) - (newZoomSize.width * factorX)) / zoomScale,
                                     ((mapScrollView.contentOffset.y + pivot.y) - (newZoomSize.height * factorY)) / zoomScale,
                                     newZoomSize.width / zoomScale,
                                     newZoomSize.height / zoomScale);
        [mapScrollView zoomToRect:zoomRect animated:animated];
    }
    else
    {
        if ([self zoom] > [self maxZoom])
            [self setZoom:[self maxZoom]];
        if ([self zoom] < [self minZoom])
            [self setZoom:[self minZoom]];
    }
}

- (float)nextNativeZoomFactor
{
    float newZoom = fminf(floorf([self zoom] + 1.0), [self maxZoom]);

    return exp2f(newZoom - [self zoom]);
}

- (float)previousNativeZoomFactor
{
    float newZoom = fmaxf(floorf([self zoom] - 1.0), [self minZoom]);

    return exp2f(newZoom - [self zoom]);
}

- (void)zoomInToNextNativeZoomAt:(CGPoint)pivot
{
    [self zoomInToNextNativeZoomAt:pivot animated:NO];
}

- (void)zoomInToNextNativeZoomAt:(CGPoint)pivot animated:(BOOL)animated
{
    // Calculate rounded zoom
    float newZoom = fmin(ceilf([self zoom]) + 0.99, [self maxZoom]);

    if (newZoom == self.zoom)
        return;

    float factor = exp2f(newZoom - [self zoom]);

    if (factor > 2.25)
    {
        newZoom = fmin(ceilf([self zoom]) - 0.01, [self maxZoom]);
        factor = exp2f(newZoom - [self zoom]);
    }

//    RMLog(@"zoom in from:%f to:%f by factor:%f around {%f,%f}", [self zoom], newZoom, factor, pivot.x, pivot.y);
    [self zoomContentByFactor:factor near:pivot animated:animated];
}

- (void)zoomOutToNextNativeZoomAt:(CGPoint)pivot
{
    [self zoomOutToNextNativeZoomAt:pivot animated:NO];
}

- (void)zoomOutToNextNativeZoomAt:(CGPoint)pivot animated:(BOOL) animated
{
    // Calculate rounded zoom
    float newZoom = fmax(floorf([self zoom]) - 0.01, [self minZoom]);

    if (newZoom == self.zoom)
        return;

    float factor = exp2f(newZoom - [self zoom]);

    if (factor > 0.75)
    {
        newZoom = fmax(floorf([self zoom]) - 1.01, [self minZoom]);
        factor = exp2f(newZoom - [self zoom]);
    }

//    RMLog(@"zoom out from:%f to:%f by factor:%f around {%f,%f}", [self zoom], newZoom, factor, pivot.x, pivot.y);
    [self zoomContentByFactor:factor near:pivot animated:animated];
}

- (void)zoomByFactor:(float)zoomFactor near:(CGPoint)center animated:(BOOL)animated
{
    if (_constrainMovement)
    {
        // check that bounds after zoom don't exceed map constraints
        float _zoomFactor = [self adjustedZoomForCurrentBoundingMask:zoomFactor];
        float zoomDelta = log2f(_zoomFactor);
        float targetZoom = zoomDelta + [self zoom];

        BOOL canZoom = NO;

        if (targetZoom == [self zoom])
        {
            //OK... . I could even do a return here.. but it will hamper with future logic..
            canZoom = YES;
        }

        // clamp zoom to remain below or equal to maxZoom after zoomAfter will be applied
        if (targetZoom > [self maxZoom])
            zoomFactor = exp2f([self maxZoom] - [self zoom]);

        // clamp zoom to remain above or equal to minZoom after zoomAfter will be applied
        if (targetZoom < [self minZoom])
            zoomFactor = 1/exp2f([self zoom] - [self minZoom]);

        // bools for syntactical sugar to understand the logic in the if statement below
        BOOL zoomAtMax = ([self zoom] == [self maxZoom]);
        BOOL zoomAtMin = ([self zoom] == [self minZoom]);
        BOOL zoomGreaterMin = ([self zoom] > [self minZoom]);
        BOOL zoomLessMax = ([self zoom] < [ self maxZoom]);

        //zooming in zoomFactor > 1
        //zooming out zoomFactor < 1
        if ((zoomGreaterMin && zoomLessMax) || (zoomAtMax && zoomFactor<1) || (zoomAtMin && zoomFactor>1))
        {
            // if I'm here it means I could zoom, now we have to see what will happen after zoom
            // get copies of mercatorRoScreenProjection's data
            RMProjectedPoint origin = [self projectedOrigin];
            CGRect screenBounds = self.bounds;

            // this is copied from [RMMercatorToScreenBounds zoomScreenByFactor]
            // First we move the origin to the pivot...
            origin.x += center.x * self.metersPerPixel;
            origin.y += (screenBounds.size.height - center.y) * self.metersPerPixel;

            // Then scale by 1/factor
            self.metersPerPixel /= _zoomFactor;

            // Then translate back
            origin.x -= center.x * self.metersPerPixel;
            origin.y -= (screenBounds.size.height - center.y) * self.metersPerPixel;

            // calculate new bounds
            RMProjectedRect zRect;
            zRect.origin = origin;
            zRect.size.width = screenBounds.size.width * self.metersPerPixel;
            zRect.size.height = screenBounds.size.height * self.metersPerPixel;

            // can zoom only if within bounds
            canZoom = !(zRect.origin.y < _southWestConstraint.y || zRect.origin.y+zRect.size.height > _northEastConstraint.y ||
                        zRect.origin.x < _southWestConstraint.x || zRect.origin.x+zRect.size.width > _northEastConstraint.x);
        }

        if (!canZoom)
        {
            RMLog(@"Zooming will move map out of bounds: no zoom");
            return;
        }
    }

    [self zoomContentByFactor:zoomFactor near:center animated:animated];
}

#pragma mark -
#pragma mark Zoom With Bounds

- (void)zoomWithLatitudeLongitudeBoundsSouthWest:(CLLocationCoordinate2D)southWest northEast:(CLLocationCoordinate2D)northEast animated:(BOOL)animated
{
    if (northEast.latitude == southWest.latitude && northEast.longitude == southWest.longitude) // There are no bounds, probably only one marker.
    {
        RMProjectedRect zoomRect;
        RMProjectedPoint myOrigin = [projection coordinateToProjectedPoint:southWest];
        // Default is with scale = 2.0 * mercators/pixel
        zoomRect.size.width = [self bounds].size.width * 2.0;
        zoomRect.size.height = [self bounds].size.height * 2.0;
        myOrigin.x = myOrigin.x - (zoomRect.size.width / 2.0);
        myOrigin.y = myOrigin.y - (zoomRect.size.height / 2.0);
        zoomRect.origin = myOrigin;
        [self setProjectedBounds:zoomRect animated:animated];
    }
    else
    {
        // Convert northEast/southWest into RMMercatorRect and call zoomWithBounds
        float pixelBuffer = kZoomRectPixelBuffer;
        CLLocationCoordinate2D midpoint = {
            .latitude = (northEast.latitude + southWest.latitude) / 2,
            .longitude = (northEast.longitude + southWest.longitude) / 2
        };
        RMProjectedPoint myOrigin = [projection coordinateToProjectedPoint:midpoint];
        RMProjectedPoint southWestPoint = [projection coordinateToProjectedPoint:southWest];
        RMProjectedPoint northEastPoint = [projection coordinateToProjectedPoint:northEast];
        RMProjectedPoint myPoint = {
            .x = northEastPoint.x - southWestPoint.x,
            .y = northEastPoint.y - southWestPoint.y
        };

		// Create the new zoom layout
        RMProjectedRect zoomRect;

        // Default is with scale = 2.0 * mercators/pixel
        zoomRect.size.width = self.bounds.size.width * 2.0;
        zoomRect.size.height = self.bounds.size.height * 2.0;

        if ((myPoint.x / self.bounds.size.width) < (myPoint.y / self.bounds.size.height))
        {
            if ((myPoint.y / (self.bounds.size.height - pixelBuffer)) > 1)
            {
                zoomRect.size.width = self.bounds.size.width * (myPoint.y / (self.bounds.size.height - pixelBuffer));
                zoomRect.size.height = self.bounds.size.height * (myPoint.y / (self.bounds.size.height - pixelBuffer));
            }
        }
        else
        {
            if ((myPoint.x / (self.bounds.size.width - pixelBuffer)) > 1)
            {
                zoomRect.size.width = self.bounds.size.width * (myPoint.x / (self.bounds.size.width - pixelBuffer));
                zoomRect.size.height = self.bounds.size.height * (myPoint.x / (self.bounds.size.width - pixelBuffer));
            }
        }

        myOrigin.x = myOrigin.x - (zoomRect.size.width / 2);
        myOrigin.y = myOrigin.y - (zoomRect.size.height / 2);
        zoomRect.origin = myOrigin;

        RMProjectedPoint topRight = RMProjectedPointMake(myOrigin.x + zoomRect.size.width, myOrigin.y + zoomRect.size.height);
        RMLog(@"zoomWithBoundingBox: {%f,%f} - {%f,%f}", [projection projectedPointToCoordinate:myOrigin].longitude, [projection projectedPointToCoordinate:myOrigin].latitude, [projection projectedPointToCoordinate:topRight].longitude, [projection projectedPointToCoordinate:topRight].latitude);

        [self setProjectedBounds:zoomRect animated:animated];
    }
}

#pragma mark -
#pragma mark Cache

- (void)removeAllCachedImages
{
    [tileCache removeAllCachedImages];
}

#pragma mark -
#pragma mark MapView (ScrollView)

- (void)createMapView
{
    [overlayView removeFromSuperview]; [overlayView release]; overlayView = nil;
    [visibleAnnotations removeAllObjects];

    [tiledLayerView removeFromSuperview]; [tiledLayerView release]; tiledLayerView = nil;

    [mapScrollView removeObserver:self forKeyPath:@"contentOffset"];
    [mapScrollView removeFromSuperview]; [mapScrollView release]; mapScrollView = nil;

    _mapScrollViewIsZooming = NO;

    int tileSideLength = [[self tileSource] tileSideLength];
    CGSize contentSize = CGSizeMake(tileSideLength, tileSideLength); // zoom level 1

    mapScrollView = [[RMScrollView alloc] initWithFrame:[self bounds]];
    mapScrollView.delegate = self;
    mapScrollView.opaque = NO;
    mapScrollView.backgroundColor = [UIColor clearColor];
    mapScrollView.showsVerticalScrollIndicator = NO;
    mapScrollView.showsHorizontalScrollIndicator = NO;
    mapScrollView.scrollsToTop = NO;
    mapScrollView.contentSize = contentSize;
    mapScrollView.minimumZoomScale = exp2f([self minZoom]);
    mapScrollView.maximumZoomScale = exp2f([self maxZoom]);
    mapScrollView.contentOffset = CGPointMake(0.0, 0.0);

    tiledLayerView = [[RMMapTiledLayerView alloc] initWithFrame:CGRectMake(0.0, 0.0, contentSize.width, contentSize.height) mapView:self];
    tiledLayerView.delegate = self;

    if (self.adjustTilesForRetinaDisplay && screenScale > 1.0)
    {
        RMLog(@"adjustTiles");
        ((CATiledLayer *)tiledLayerView.layer).tileSize = CGSizeMake(tileSideLength * 2.0, tileSideLength * 2.0);
    }
    else
    {
        ((CATiledLayer *)tiledLayerView.layer).tileSize = CGSizeMake(tileSideLength, tileSideLength);
    }

    [mapScrollView addSubview:tiledLayerView];

    [mapScrollView addObserver:self forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:NULL];
    [mapScrollView setZoomScale:exp2f([self zoom]) animated:NO];

    _lastZoom = [self zoom];
    _lastContentOffset = mapScrollView.contentOffset;
    _accumulatedDelta = CGPointMake(0.0, 0.0);

    if (backgroundView)
        [self insertSubview:mapScrollView aboveSubview:backgroundView];
    else
        [self insertSubview:mapScrollView atIndex:0];

    overlayView = [[RMMapOverlayView alloc] initWithFrame:[self bounds]];
    overlayView.delegate = self;

    [self insertSubview:overlayView aboveSubview:mapScrollView];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView
{
    return tiledLayerView;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if (_delegateHasBeforeMapMove)
        [delegate beforeMapMove:self];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate && _delegateHasAfterMapMove)
        [delegate afterMapMove:self];
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView
{
    if (decelerationMode == RMMapDecelerationOff)
        [scrollView setContentOffset:scrollView.contentOffset animated:NO];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    if (_delegateHasAfterMapMove)
        [delegate afterMapMove:self];
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view
{
    _mapScrollViewIsZooming = YES;

    if (_delegateHasBeforeMapZoom)
        [delegate beforeMapZoom:self];
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(float)scale
{
    _mapScrollViewIsZooming = NO;

    [self correctPositionOfAllAnnotations];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView
{
    [self correctPositionOfAllAnnotations];

    if (_delegateHasAfterMapZoom)
        [delegate afterMapZoom:self];
}

// Overlay

- (void)mapOverlayView:(RMMapOverlayView *)aMapOverlayView tapOnAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (_delegateHasTapOnAnnotation && anAnnotation)
    {
        [delegate tapOnAnnotation:anAnnotation onMap:self];
    }
    else
    {
        if (_delegateHasSingleTapOnMap)
            [delegate singleTapOnMap:self at:aPoint];   
    }
}

- (void)mapOverlayView:(RMMapOverlayView *)aMapOverlayView doubleTapOnAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (_delegateHasDoubleTapOnAnnotation && anAnnotation)
    {
        [delegate doubleTapOnAnnotation:anAnnotation onMap:self];
    }
    else
    {
        [self zoomInToNextNativeZoomAt:aPoint animated:YES];

        if (_delegateHasDoubleTapOnMap)
            [delegate doubleTapOnMap:self at:aPoint];
    }
}

- (void)mapOverlayView:(RMMapOverlayView *)aMapOverlayView tapOnLabelForAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (_delegateHasTapOnLabelForAnnotation && anAnnotation)
    {
        [delegate tapOnLabelForAnnotation:anAnnotation onMap:self];
    }
    else
    {
        if (_delegateHasSingleTapOnMap)
            [delegate singleTapOnMap:self at:aPoint];
    }
}

- (void)mapOverlayView:(RMMapOverlayView *)aMapOverlayView doubleTapOnLabelForAnnotation:(RMAnnotation *)anAnnotation atPoint:(CGPoint)aPoint
{
    if (_delegateHasDoubleTapOnLabelForAnnotation && anAnnotation)
    {
        [delegate doubleTapOnLabelForAnnotation:anAnnotation onMap:self];
    }
    else
    {
        [self zoomInToNextNativeZoomAt:aPoint animated:YES];

        if (_delegateHasDoubleTapOnMap)
            [delegate doubleTapOnMap:self at:aPoint];
    }
}

- (BOOL)mapOverlayView:(RMMapOverlayView *)aMapOverlayView shouldDragAnnotation:(RMAnnotation *)anAnnotation
{
    if (_delegateHasShouldDragMarker)
        return [delegate mapView:self shouldDragAnnotation:anAnnotation];
    else
        return NO;
}

- (void)mapOverlayView:(RMMapOverlayView *)aMapOverlayView didDragAnnotation:(RMAnnotation *)anAnnotation withDelta:(CGPoint)delta
{
    if (_delegateHasDidDragMarker)
        [delegate mapView:self didDragAnnotation:anAnnotation withDelta:delta];
}

- (void)mapOverlayView:(RMMapOverlayView *)aMapOverlayView didEndDragAnnotation:(RMAnnotation *)anAnnotation
{
    if (_delegateHasDidEndDragMarker)
        [delegate mapView:self didEndDragAnnotation:anAnnotation];
}

// Tiled layer

- (void)mapTiledLayerView:(RMMapTiledLayerView *)aTiledLayerView singleTapAtPoint:(CGPoint)aPoint
{
    if (_delegateHasSingleTapOnMap)
        [delegate singleTapOnMap:self at:aPoint];
}

- (void)mapTiledLayerView:(RMMapTiledLayerView *)aTiledLayerView doubleTapAtPoint:(CGPoint)aPoint
{
    [self zoomInToNextNativeZoomAt:aPoint animated:YES];

    if (_delegateHasDoubleTapOnMap)
        [delegate doubleTapOnMap:self at:aPoint];
}

- (void)mapTiledLayerView:(RMMapTiledLayerView *)aTiledLayerView twoFingerDoubleTapAtPoint:(CGPoint)aPoint
{
    [self zoomOutToNextNativeZoomAt:aPoint animated:YES];

    if (_delegateHasDoubleTapTwoFingersOnMap)
        [delegate doubleTapTwoFingersOnMap:self at:aPoint];
}

- (void)mapTiledLayerView:(RMMapTiledLayerView *)aTiledLayerView twoFingerSingleTapAtPoint:(CGPoint)aPoint
{
    [self zoomOutToNextNativeZoomAt:aPoint animated:YES];

    if (_delegateHasSingleTapTwoFingersOnMap)
        [delegate singleTapTwoFingersOnMap:self at:aPoint];
}

- (void)mapTiledLayerView:(RMMapTiledLayerView *)aTiledLayerView longPressAtPoint:(CGPoint)aPoint
{
    if (_delegateHasLongSingleTapOnMap)
        [delegate longSingleTapOnMap:self at:aPoint];
}

// Detect dragging/zooming

- (void)observeValueForKeyPath:(NSString *)aKeyPath ofObject:(id)anObject change:(NSDictionary *)change context:(void *)context
{
    RMProjectedRect planetBounds = projection.planetBounds;
    metersPerPixel = planetBounds.size.width / mapScrollView.contentSize.width;
    zoom = log2f(mapScrollView.zoomScale);

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(correctPositionOfAllAnnotations) object:nil];

    if (_constrainMovement && ![self projectedBounds:tileSourceProjectedBounds containsPoint:[self centerProjectedPoint]])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [mapScrollView setContentOffset:_lastContentOffset animated:NO];
        });

        return;
    }

    if (zoom == _lastZoom)
    {
        CGPoint contentOffset = mapScrollView.contentOffset;
        CGPoint delta = CGPointMake(_lastContentOffset.x - contentOffset.x, _lastContentOffset.y - contentOffset.y);
        _accumulatedDelta.x += delta.x;
        _accumulatedDelta.y += delta.y;

        if (fabsf(_accumulatedDelta.x) < kZoomRectPixelBuffer && fabsf(_accumulatedDelta.y) < kZoomRectPixelBuffer)
        {
            [overlayView moveLayersBy:_accumulatedDelta];
            [self performSelector:@selector(correctPositionOfAllAnnotations) withObject:nil afterDelay:0.1];
        }
        else
        {
            if (_mapScrollViewIsZooming)
                [self correctPositionOfAllAnnotationsIncludingInvisibles:NO wasZoom:YES];
            else
                [self correctPositionOfAllAnnotations];
        }
    }
    else
    {
        [self correctPositionOfAllAnnotationsIncludingInvisibles:NO wasZoom:YES];
        _lastZoom = zoom;
    }

    _lastContentOffset = mapScrollView.contentOffset;

    // Don't do anything stupid here or your scrolling experience will suck
    if (_delegateHasMapViewRegionDidChange)
        [delegate mapViewRegionDidChange:self];
}

#pragma mark -
#pragma mark Snapshots

- (UIImage *)takeSnapshotInRect:(CGRect)snapshotRect includeOverlay:(BOOL)includeOverlay
{
    RMProjectedRect bounds = [self projectedBounds];

    CLLocationCoordinate2D bottomLeft = [projection projectedPointToCoordinate:bounds.origin];
    CLLocationCoordinate2D topRight = [projection projectedPointToCoordinate:RMProjectedPointMake(bounds.origin.x + bounds.size.width, bounds.origin.y + bounds.size.height)];

    RMTile baseTile = [self tileWithCoordinate:bottomLeft andZoom:ceilf(zoom)];
    RMTile borderTile = [self tileWithCoordinate:topRight andZoom:ceilf(zoom)];

//    RMLog(@"x:%d, y:%d, zoom:%d (real zoom:%f)", baseTile.x, baseTile.y, baseTile.zoom, zoom);
//    RMLog(@"-> x:%d, y:%d, zoom:%d (real zoom:%f)", borderTile.x, borderTile.y, borderTile.zoom, zoom);

    CATiledLayer *tiledLayer = (CATiledLayer *)tiledLayerView.layer;
    CGSize tileSize = tiledLayer.tileSize;

    int tilesX = borderTile.x - baseTile.x + 1;
    int tilesY = baseTile.y - borderTile.y + 1;

//    RMLog(@"tiles x=%d, y=%d", tilesX, tilesY);

    int scale = (1<<(int)ceilf(zoom));
	CLLocationCoordinate2D normalizedCoordinate = [self normalizeCoordinate:bottomLeft];

    CGFloat leftBorder = round(((normalizedCoordinate.longitude * scale) * tileSize.width) - (baseTile.x * tileSize.width));
    CGFloat topBorder = (tilesY * tileSize.height) - (256.0 - round(((normalizedCoordinate.latitude * scale) * tileSize.height) - (baseTile.y * tileSize.height))) - self.bounds.size.height;

//    RMLog(@"left: %f, top:%f", leftBorder, topBorder);

    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, [[UIScreen mainScreen] scale]);

    for (int column=0; column<tilesX; column++)
    {
        for (int row=0; row<tilesY; row++)
        {
//            RMLog(@"x:%d, y:%d, zoom:%d", baseTile.x + column, borderTile.y + row, baseTile.zoom);

            UIImage *tileImage = [tileSource imageForTile:RMTileMake(baseTile.x + column, borderTile.y + row, baseTile.zoom) inCache:tileCache];

            if (tileImage)
            {
                [tileImage drawInRect:CGRectMake(column * tileSize.width - leftBorder,
                                                 row * tileSize.height - topBorder,
                                                 tileSize.width,
                                                 tileSize.height)];
            }
        }
    }

    if (includeOverlay)
    {
        UIGraphicsBeginImageContextWithOptions(overlayView.bounds.size, NO, [[UIScreen mainScreen] scale]);

        [overlayView.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *overlayImage = UIGraphicsGetImageFromCurrentImageContext();

        UIGraphicsEndImageContext();

        [overlayImage drawInRect:CGRectMake(0.0, 0.0, overlayView.bounds.size.width, overlayView.bounds.size.height)];
    }

    // final image
    UIImage *finalImage = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    if (!CGRectEqualToRect(self.bounds, snapshotRect))
    {
        CGImageRef imageRef = CGImageCreateWithImageInRect([finalImage CGImage], snapshotRect);
        finalImage = [UIImage imageWithCGImage:imageRef];
        CGImageRelease(imageRef);
    }

    return finalImage;
}

- (UIImage *)takeSnapshot
{
    return [self takeSnapshotInRect:self.bounds includeOverlay:YES];
}

#pragma mark -
#pragma mark Properties

- (id <RMTileSource>)tileSource
{
    return [[tileSource retain] autorelease];
}

- (void)setTileSource:(id <RMTileSource>)newTileSource
{
    if (tileSource == newTileSource)
        return;

    [tileSource cancelAllDownloads];
    [tileSource autorelease];
    tileSource = [newTileSource retain];

    [projection release];
    projection = [[tileSource projection] retain];

    [mercatorToTileProjection release];
    mercatorToTileProjection = [[tileSource mercatorToTileProjection] retain];
    tileSourceProjectedBounds = (RMProjectedRect)[self projectedRectFromLatitudeLongitudeBounds:[tileSource latitudeLongitudeBoundingBox]];

    RMSphericalTrapezium bounds = [tileSource latitudeLongitudeBoundingBox];
    _constrainMovement = !(bounds.northEast.latitude == 90 && bounds.northEast.longitude == 180 && bounds.southWest.latitude == -90 && bounds.southWest.longitude == -180);

    [self setMinZoom:newTileSource.minZoom];
    [self setMaxZoom:newTileSource.maxZoom];
    [self setZoom:[self zoom]]; // setZoom clamps zoom level to min/max limits

    // Reload the map with the new tilesource
    tiledLayerView.layer.contents = nil;
    [tiledLayerView.layer setNeedsDisplay];
}

- (UIView *)backgroundView
{
    return [[backgroundView retain] autorelease];
}

- (void)setBackgroundView:(UIView *)aView
{
    if (backgroundView == aView)
        return;

    if (backgroundView != nil)
    {
        [backgroundView removeFromSuperview];
        [backgroundView release];
    }

    backgroundView = [aView retain];
    if (backgroundView == nil)
        return;

    backgroundView.frame = [self bounds];

    [self insertSubview:backgroundView atIndex:0];
}

- (double)metersPerPixel
{
    return metersPerPixel;
}

- (void)setMetersPerPixel:(double)newMetersPerPixel
{
    [self setMetersPerPixel:newMetersPerPixel animated:YES];
}

- (void)setMetersPerPixel:(double)newMetersPerPixel animated:(BOOL)animated
{
    double factor = self.metersPerPixel / newMetersPerPixel;

    [self zoomContentByFactor:factor near:CGPointMake(self.bounds.size.width/2.0, self.bounds.size.height/2.0) animated:animated];
}

- (double)scaledMetersPerPixel
{
    return self.metersPerPixel / screenScale;
}

- (double)scaleDenominator
{
    double routemeMetersPerPixel = self.metersPerPixel;
    double iphoneMillimetersPerPixel = kiPhoneMilimeteresPerPixel;
    double truescaleDenominator = routemeMetersPerPixel / (0.001 * iphoneMillimetersPerPixel);

    return truescaleDenominator;
}

- (void)setMinZoom:(float)newMinZoom
{
    minZoom = newMinZoom;

//    RMLog(@"New minZoom:%f", newMinZoom);

    mapScrollView.minimumZoomScale = exp2f(newMinZoom);
}

- (void)setMaxZoom:(float)newMaxZoom
{
    maxZoom = newMaxZoom;

//    RMLog(@"New maxZoom:%f", newMaxZoom);

    mapScrollView.maximumZoomScale = exp2f(newMaxZoom);
}

- (float)zoom
{
    return zoom;
}

// if #zoom is outside of range #minZoom to #maxZoom, zoom level is clamped to that range.
- (void)setZoom:(float)newZoom
{
    zoom = (newZoom > maxZoom) ? maxZoom : newZoom;
    zoom = (zoom < minZoom) ? minZoom : zoom;

//    RMLog(@"New zoom:%f", zoom);

    mapScrollView.zoomScale = exp2f(zoom);
}

- (void)setEnableClustering:(BOOL)doEnableClustering
{
    enableClustering = doEnableClustering;

    [self correctPositionOfAllAnnotations];
}

- (void)setDecelerationMode:(RMMapDecelerationMode)aDecelerationMode
{
    decelerationMode = aDecelerationMode;

    float decelerationRate = 0.0;

    if (aDecelerationMode == RMMapDecelerationNormal)
        decelerationRate = UIScrollViewDecelerationRateNormal;
    else if (aDecelerationMode == RMMapDecelerationFast)
        decelerationRate = UIScrollViewDecelerationRateFast;

    [mapScrollView setDecelerationRate:decelerationRate];
}

- (BOOL)enableDragging
{
    return mapScrollView.scrollEnabled;
}

- (void)setEnableDragging:(BOOL)enableDragging
{
    mapScrollView.scrollEnabled = enableDragging;
}

- (void)setAdjustTilesForRetinaDisplay:(BOOL)doAdjustTilesForRetinaDisplay
{
    if (adjustTilesForRetinaDisplay == doAdjustTilesForRetinaDisplay)
        return;

    adjustTilesForRetinaDisplay = doAdjustTilesForRetinaDisplay;

    [self createMapView];
}

- (RMProjection *)projection
{
    return [[projection retain] autorelease];
}

- (RMFractalTileProjection *)mercatorToTileProjection
{
    return [[mercatorToTileProjection retain] autorelease];
}

#pragma mark -
#pragma mark LatLng/Pixel translation functions

- (CGPoint)projectedPointToPixel:(RMProjectedPoint)projectedPoint
{
    RMProjectedRect planetBounds = projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = projectedPoint.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = projectedPoint.y + fabs(planetBounds.origin.y);

    // \bug: There is a rounding error here for high zoom levels
    CGPoint projectedPixel = CGPointMake((normalizedProjectedPoint.x / self.metersPerPixel) - mapScrollView.contentOffset.x, (mapScrollView.contentSize.height - (normalizedProjectedPoint.y / self.metersPerPixel)) - mapScrollView.contentOffset.y);

//    RMLog(@"pointToPixel: {%f,%f} -> {%f,%f}", projectedPoint.x, projectedPoint.y, projectedPixel.x, projectedPixel.y);

    return projectedPixel;
}

- (CGPoint)coordinateToPixel:(CLLocationCoordinate2D)coordinate
{
    return [self projectedPointToPixel:[projection coordinateToProjectedPoint:coordinate]];
}

- (RMProjectedPoint)pixelToProjectedPoint:(CGPoint)pixelCoordinate
{
    RMProjectedRect planetBounds = projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
    normalizedProjectedPoint.x = ((pixelCoordinate.x + mapScrollView.contentOffset.x) * self.metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedPoint.y = ((mapScrollView.contentSize.height - mapScrollView.contentOffset.y - pixelCoordinate.y) * self.metersPerPixel) - fabs(planetBounds.origin.y);

//    RMLog(@"pixelToPoint: {%f,%f} -> {%f,%f}", pixelCoordinate.x, pixelCoordinate.y, normalizedProjectedPoint.x, normalizedProjectedPoint.y);

    return normalizedProjectedPoint;
}

- (CLLocationCoordinate2D)pixelToCoordinate:(CGPoint)pixelCoordinate
{
    return [projection projectedPointToCoordinate:[self pixelToProjectedPoint:pixelCoordinate]];
}

- (RMProjectedSize)viewSizeToProjectedSize:(CGSize)screenSize
{
    return RMProjectedSizeMake(screenSize.width * self.metersPerPixel, screenSize.height * self.metersPerPixel);
}

- (CGSize)projectedSizeToViewSize:(RMProjectedSize)projectedSize
{
    return CGSizeMake(projectedSize.width / self.metersPerPixel, projectedSize.height / self.metersPerPixel);
}

- (RMProjectedPoint)projectedOrigin
{
    CGPoint origin = CGPointMake(mapScrollView.contentOffset.x, mapScrollView.contentSize.height - mapScrollView.contentOffset.y);

    RMProjectedRect planetBounds = projection.planetBounds;
    RMProjectedPoint normalizedProjectedPoint;
    normalizedProjectedPoint.x = (origin.x * self.metersPerPixel) - fabs(planetBounds.origin.x);
    normalizedProjectedPoint.y = (origin.y * self.metersPerPixel) - fabs(planetBounds.origin.y);

//    RMLog(@"projectedOrigin: {%f,%f}", normalizedProjectedPoint.x, normalizedProjectedPoint.y);

    return normalizedProjectedPoint;
}

- (RMProjectedSize)projectedViewSize
{
    return RMProjectedSizeMake(self.bounds.size.width * self.metersPerPixel, self.bounds.size.height * self.metersPerPixel);
}

- (CLLocationCoordinate2D)normalizeCoordinate:(CLLocationCoordinate2D)coordinate
{
	if (coordinate.longitude > 180)
        coordinate.longitude -= 360;

	coordinate.longitude /= 360.0;
	coordinate.longitude += 0.5;
	coordinate.latitude = 0.5 - ((log(tan((M_PI_4) + ((0.5 * M_PI * coordinate.latitude) / 180.0))) / M_PI) / 2.0);

	return coordinate;
}

- (RMTile)tileWithCoordinate:(CLLocationCoordinate2D)coordinate andZoom:(int)tileZoom
{
	int scale = (1<<tileZoom);
	CLLocationCoordinate2D normalizedCoordinate = [self normalizeCoordinate:coordinate];

	RMTile returnTile;
	returnTile.x = (int)(normalizedCoordinate.longitude * scale);
	returnTile.y = (int)(normalizedCoordinate.latitude * scale);
	returnTile.zoom = tileZoom;

	return returnTile;
}

#pragma mark -
#pragma mark Markers and overlays

- (RMSphericalTrapezium)latitudeLongitudeBoundingBox
{
    return [self latitudeLongitudeBoundingBoxFor:[self bounds]];
}

- (RMSphericalTrapezium)latitudeLongitudeBoundingBoxFor:(CGRect)rect
{
    RMSphericalTrapezium boundingBox;
    CGPoint northwestScreen = rect.origin;

    CGPoint southeastScreen;
    southeastScreen.x = rect.origin.x + rect.size.width;
    southeastScreen.y = rect.origin.y + rect.size.height;

    CGPoint northeastScreen, southwestScreen;
    northeastScreen.x = southeastScreen.x;
    northeastScreen.y = northwestScreen.y;
    southwestScreen.x = northwestScreen.x;
    southwestScreen.y = southeastScreen.y;

    CLLocationCoordinate2D northeastLL, northwestLL, southeastLL, southwestLL;
    northeastLL = [self pixelToCoordinate:northeastScreen];
    northwestLL = [self pixelToCoordinate:northwestScreen];
    southeastLL = [self pixelToCoordinate:southeastScreen];
    southwestLL = [self pixelToCoordinate:southwestScreen];

    boundingBox.northEast.latitude = fmax(northeastLL.latitude, northwestLL.latitude);
    boundingBox.southWest.latitude = fmin(southeastLL.latitude, southwestLL.latitude);

    // westerly computations:
    // -179, -178 -> -179 (min)
    // -179, 179  -> 179 (max)
    if (fabs(northwestLL.longitude - southwestLL.longitude) <= kMaxLong)
        boundingBox.southWest.longitude = fmin(northwestLL.longitude, southwestLL.longitude);
    else
        boundingBox.southWest.longitude = fmax(northwestLL.longitude, southwestLL.longitude);

    if (fabs(northeastLL.longitude - southeastLL.longitude) <= kMaxLong)
        boundingBox.northEast.longitude = fmax(northeastLL.longitude, southeastLL.longitude);
    else
        boundingBox.northEast.longitude = fmin(northeastLL.longitude, southeastLL.longitude);

    return boundingBox;
}

#pragma mark -
#pragma mark Annotations

- (void)correctScreenPosition:(RMAnnotation *)annotation
{
    RMProjectedRect planetBounds = projection.planetBounds;
	RMProjectedPoint normalizedProjectedPoint;
	normalizedProjectedPoint.x = annotation.projectedLocation.x + fabs(planetBounds.origin.x);
	normalizedProjectedPoint.y = annotation.projectedLocation.y + fabs(planetBounds.origin.y);

    annotation.position = CGPointMake((normalizedProjectedPoint.x / self.metersPerPixel) - mapScrollView.contentOffset.x, mapScrollView.contentSize.height - (normalizedProjectedPoint.y / self.metersPerPixel) - mapScrollView.contentOffset.y);
//    RMLog(@"Change annotation at {%f,%f} in mapView {%f,%f}", annotation.position.x, annotation.position.y, mapScrollView.contentSize.width, mapScrollView.contentSize.height);
}

- (void)correctPositionOfAllAnnotationsIncludingInvisibles:(BOOL)correctAllAnnotations wasZoom:(BOOL)wasZoom
{
    // Prevent blurry movements
    [CATransaction begin];

    // Synchronize marker movement with the map scroll view
    if (wasZoom && !mapScrollView.isZooming)
    {
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        [CATransaction setAnimationDuration:0.30];
    }
    else
    {
        [CATransaction setAnimationDuration:0.0];
    }

    _accumulatedDelta.x = 0.0;
    _accumulatedDelta.y = 0.0;
    [overlayView moveLayersBy:_accumulatedDelta];

    if (self.quadTree)
    {
        if (!correctAllAnnotations || _mapScrollViewIsZooming)
        {
            for (RMAnnotation *annotation in visibleAnnotations)
                [self correctScreenPosition:annotation];

//            RMLog(@"%d annotations corrected", [visibleAnnotations count]);

            [CATransaction commit];

            return;
        }

        RMProjectedRect boundingBox = [self projectedBounds];
        double boundingBoxBuffer = kZoomRectPixelBuffer * self.metersPerPixel;
        boundingBox.origin.x -= boundingBoxBuffer;
        boundingBox.origin.y -= boundingBoxBuffer;
        boundingBox.size.width += 2*boundingBoxBuffer;
        boundingBox.size.height += 2*boundingBoxBuffer;

        NSArray *annotationsToCorrect = [quadTree annotationsInProjectedRect:boundingBox createClusterAnnotations:self.enableClustering withClusterSize:RMProjectedSizeMake(self.clusterMarkerSize.width * self.metersPerPixel, self.clusterMarkerSize.height * self.metersPerPixel) findGravityCenter:self.positionClusterMarkersAtTheGravityCenter];
        NSMutableSet *previousVisibleAnnotations = [[NSMutableSet alloc] initWithSet:visibleAnnotations];

        for (RMAnnotation *annotation in annotationsToCorrect)
        {
            if (annotation.layer == nil && _delegateHasLayerForAnnotation)
                annotation.layer = [delegate mapView:self layerForAnnotation:annotation];
            if (annotation.layer == nil)
                continue;

            // Use the zPosition property to order the layer hierarchy
            if (![visibleAnnotations containsObject:annotation])
            {
                [overlayView addSublayer:annotation.layer];
                [visibleAnnotations addObject:annotation];
            }

            [self correctScreenPosition:annotation];

            [previousVisibleAnnotations removeObject:annotation];
        }

        for (RMAnnotation *annotation in previousVisibleAnnotations)
        {
            if (_delegateHasWillHideLayerForAnnotation)
                [delegate mapView:self willHideLayerForAnnotation:annotation];

            annotation.layer = nil;

            if (_delegateHasDidHideLayerForAnnotation)
                [delegate mapView:self didHideLayerForAnnotation:annotation];

            [visibleAnnotations removeObject:annotation];
        }

        [previousVisibleAnnotations release];

//        RMLog(@"%d annotations on screen, %d total", [overlayView sublayersCount], [annotations count]);
    }
    else
    {
        CALayer *lastLayer = nil;

        @synchronized (annotations)
        {
            if (correctAllAnnotations)
            {
                for (RMAnnotation *annotation in annotations)
                {
                    [self correctScreenPosition:annotation];

                    if ([annotation isAnnotationWithinBounds:[self bounds]])
                    {
                        if (annotation.layer == nil && _delegateHasLayerForAnnotation)
                            annotation.layer = [delegate mapView:self layerForAnnotation:annotation];
                        if (annotation.layer == nil)
                            continue;

                        if (![visibleAnnotations containsObject:annotation])
                        {
                            if (!lastLayer)
                                [overlayView insertSublayer:annotation.layer atIndex:0];
                            else
                                [overlayView insertSublayer:annotation.layer above:lastLayer];

                            [visibleAnnotations addObject:annotation];
                        }

                        lastLayer = annotation.layer;
                    }
                    else
                    {
                        if (_delegateHasWillHideLayerForAnnotation)
                            [delegate mapView:self willHideLayerForAnnotation:annotation];

                        annotation.layer = nil;
                        [visibleAnnotations removeObject:annotation];

                        if (_delegateHasDidHideLayerForAnnotation)
                            [delegate mapView:self didHideLayerForAnnotation:annotation];
                    }
                }
//                RMLog(@"%d annotations on screen, %d total", [overlayView sublayersCount], [annotations count]);
            }
            else
            {
                for (RMAnnotation *annotation in visibleAnnotations)
                    [self correctScreenPosition:annotation];

//                RMLog(@"%d annotations corrected", [visibleAnnotations count]);
            }
        }
    }

    [CATransaction commit];
}

- (void)correctPositionOfAllAnnotations
{
    [self correctPositionOfAllAnnotationsIncludingInvisibles:YES wasZoom:NO];
}

- (NSArray *)annotations
{
    return [NSArray arrayWithArray:annotations];
}

- (void)addAnnotation:(RMAnnotation *)annotation
{
    @synchronized (annotations)
    {
        [annotations addObject:annotation];
        [self.quadTree addAnnotation:annotation];
    }

    if (enableClustering)
    {
        [self correctPositionOfAllAnnotations];
    }
    else
    {
        [self correctScreenPosition:annotation];

        if ([annotation isAnnotationOnScreen] && [delegate respondsToSelector:@selector(mapView:layerForAnnotation:)])
        {
            annotation.layer = [delegate mapView:self layerForAnnotation:annotation];

            if (annotation.layer)
            {
                [overlayView addSublayer:annotation.layer];
                [visibleAnnotations addObject:annotation];
            }
        }
    }
}

- (void)addAnnotations:(NSArray *)newAnnotations
{
    @synchronized (annotations)
    {
        for (RMAnnotation *annotation in newAnnotations)
        {
            [annotations addObject:annotation];
            [self.quadTree addAnnotation:annotation];
        }
    }

    [self correctPositionOfAllAnnotationsIncludingInvisibles:YES wasZoom:NO];
}

- (void)removeAnnotation:(RMAnnotation *)annotation
{
    @synchronized (annotations)
    {
        [annotations removeObject:annotation];
        [visibleAnnotations removeObject:annotation];
    }

    [self.quadTree removeAnnotation:annotation];

    // Remove the layer from the screen
    annotation.layer = nil;
}

- (void)removeAnnotations:(NSArray *)annotationsToRemove
{
    @synchronized (annotations)
    {
        for (RMAnnotation *annotation in annotationsToRemove)
        {
            [annotations removeObject:annotation];
            [visibleAnnotations removeObject:annotation];
            [self.quadTree removeAnnotation:annotation];
            annotation.layer = nil;
       }
    }

    [self correctPositionOfAllAnnotations];
}

- (void)removeAllAnnotations
{
    @synchronized (annotations)
    {
        for (RMAnnotation *annotation in annotations)
        {
            // Remove the layer from the screen
            annotation.layer = nil;
        }
    }

    [annotations removeAllObjects];
    [visibleAnnotations removeAllObjects];
    [quadTree removeAllObjects];
    [self correctPositionOfAllAnnotations];
}

- (CGPoint)screenCoordinatesForAnnotation:(RMAnnotation *)annotation
{
    [self correctScreenPosition:annotation];
    return annotation.position;
}

@end
