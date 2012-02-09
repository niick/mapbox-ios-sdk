//
//  RMScrollView.m
//  MapView
//
//  Created by Justin Miller on 1/30/12.
//  Copyright (c) 2012 Development Seed. All rights reserved.
//

#import "RMScrollView.h"

@implementation RMScrollView

@synthesize animationDuration;

- (id)initWithFrame:(CGRect)aRect
{
    self = [super initWithFrame:aRect];
    
    if (self)
        animationDuration = 1.0;
    
    return self;
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated
{
    [UIView animateWithDuration:(animated ? self.animationDuration : 0.0)
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState & UIViewAnimationCurveEaseInOut
                     animations:^(void)
                     {
                         [super setContentOffset:contentOffset animated:NO];
                     } 
                     completion:nil];
}

- (void)zoomToRect:(CGRect)rect animated:(BOOL)animated
{
    [UIView animateWithDuration:(animated ? self.animationDuration : 0.0)
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState & UIViewAnimationCurveEaseInOut
                     animations:^(void)
                     {
                         [super zoomToRect:rect animated:NO];
                     } 
                     completion:nil];
}

@end