/* @license
 * This file is part of the Game Closure SDK.
 *
 * The Game Closure SDK is free software: you can redistribute it and/or modify
 * it under the terms of the Mozilla Public License v. 2.0 as published by Mozilla.
 
 * The Game Closure SDK is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * Mozilla Public License v. 2.0 for more details.
 
 * You should have received a copy of the Mozilla Public License v. 2.0
 * along with the Game Closure SDK.	 If not, see <http://mozilla.org/MPL/2.0/>.
 */

#import "OpenGLView.h"
#include "core/core.h"
#include "core/tealeaf_context.h"
#import "TextInputManager.h"
#import "TeaLeafAppDelegate.h"
#import "UITouchWrapper.h"
#import "platform/log.h"

void timestep_animation_tick_animations(double);

@implementation OpenGLView

static CADisplayLink *displayLink;

- (id)init {
	self = [super init];
	if (self) {
		cond = [NSCondition new];
	}

	return self;
}

- (void)dealloc
{
	NSLog(@"Exciting: Deallocating OpenGLView");
	
	[self destroyDisplayLink];

	[super dealloc];
}

+ (Class)layerClass {
	return [CAEAGLLayer class];
}

- (void)setupLayer {
	_eaglLayer = (CAEAGLLayer*) self.layer;
	_eaglLayer.opaque = YES;
}

- (void)setupContext {	 
	EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES2;
	_context = [[EAGLContext alloc] initWithAPI:api];
	if (!_context) {
		NSLOG(@"{glview} FATAL: Failed to initialize OpenGLES 2.0 context");
		exit(1);
	}
	
	if (![EAGLContext setCurrentContext:_context]) {
		NSLOG(@"{glview} FATAL: Failed to set current OpenGL context");
		exit(1);
	}
}

- (void)setupRenderBuffer {
	GLTRACE(glGenRenderbuffers(1, &_colorRenderBuffer));
	GLTRACE(glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderBuffer));
	[_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];		
}


- (void)setupFrameBuffer {	  
	GLuint framebuffer;
	GLTRACE(glGenFramebuffers(1, &framebuffer));
	GLTRACE(glBindFramebuffer(GL_FRAMEBUFFER, framebuffer));
	GLTRACE(glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderBuffer));
}

static CFTimeInterval last_timestamp = 0.0f;


//// Start/Stop Rendering

#include <libkern/OSAtomic.h>

static volatile BOOL m_ogl_en = NO; // OpenGL calls enabled
static volatile BOOL m_ogl_in = NO; // In OpenGL calls right now?

- (void)startRendering {
	m_ogl_en = YES;
}

- (void)stopRendering {
	m_ogl_en = NO;

	[cond lock];
	while (m_ogl_in) {
		[cond wait];
	}
	[cond unlock];
}

- (void)render:(CADisplayLink*)displayLink {
	m_ogl_in = YES;

	// Compiler memory barrier
	__asm__ volatile("" ::: "memory");

	if (m_ogl_en) {
		CFTimeInterval timestamp = CFAbsoluteTimeGetCurrent();
		int dt = (int)(1000 * (timestamp - last_timestamp));
		core_tick(dt);
		
		// Measure time to perform a tick
		// CFTimeInterval after_tick = CFAbsoluteTimeGetCurrent();

		last_timestamp = timestamp;
		[_context presentRenderbuffer:GL_RENDERBUFFER];

		/*
		 // Limit to 30 FPS
		 int tick_dt = (int)(1000 * (after_tick - timestamp));
		 if (tick_dt < 30) {
		 // Measure time to perform gc
		 CFTimeInterval before_gc = CFAbsoluteTimeGetCurrent();
		 
		 JS_MaybeGC(get_js_context());
		 
		 // Measure time to perform gc
		 CFTimeInterval after_gc = CFAbsoluteTimeGetCurrent();
		 
		 int gc_dt = (int)(1000 * (after_gc - before_gc));
		 
		 if (gc_dt + tick_dt < 30) {
		 int sleep_ms = 30 - (gc_dt + tick_dt);
		 [NSThread sleepForTimeInterval:(sleep_ms / 1000.0)];
		 }
		 }*/
	}

	m_ogl_in = NO;

	if (!m_ogl_en) {
		[cond lock];
		[cond signal];
		[cond unlock];
	}
}

- (void)setupDisplayLink {
	// Enable multi-touch
	self.multipleTouchEnabled = YES;
	
	displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(render:)];
	displayLink.frameInterval = 1;
	[displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)destroyDisplayLink {
	[self stopRendering];

	[displayLink removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

	[_context release];
	_context = nil;
}


- (id)initWithFrame:(CGRect)frame {
	NSLog(@"{OpenGL} Init with frame");

	self = [super initWithFrame:frame];
	if (self) {
		// Adjust for retina displays
		if ([self respondsToSelector:@selector(setContentScaleFactor:)]) {
			[self setContentScaleFactor:[UIScreen mainScreen].scale];
		}

		touchData = [[NSMutableArray alloc] init];
		[self setupLayer];		  
		[self setupContext];  
		[self setupRenderBuffer];
		[self setupFrameBuffer];

		[self setupDisplayLink];
		_id = 0;
	}
	return self;
}

-(int) getTouchOffsetX {
	return 0;
}


-(int) getTouchOffsetY {
	return 0;
}

// Handles the start of a touch
-(void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	[[TextInputManager get] dismissAll];
	for (UITouch *t in touches) {
		UITouchWrapper *wrapper = [[UITouchWrapper alloc] initWithUITouch: t andView: self andId: _id++];
		[touchData addObject: wrapper];
		[wrapper release];
	}
}

-(void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	for (UITouch *t in touches) {
		for (UITouchWrapper *w in touchData) {
			if ([w isForUITouch:t]) {
				[w updateWithUITouch: t forView: self];
				break;
			}
		}
	}
}

// Handles the end of a touch event.
-(void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	for (UITouch *t in touches) {
		for (UITouchWrapper *w in touchData) {
			if ([w isForUITouch:t]) {
				[w removeWithUITouch: t forView: self];
				[touchData removeObject:w];
				break;
			}
		}
	}
	if ([touchData count] == 0) {
		_id = 0;
	}
}

// Touches cancelled by system event: e.g. phone call
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
	for (UITouch *t in touches) {
		for (UITouchWrapper *w in touchData) {
			if ([w isForUITouch:t]) {
				[w removeWithUITouch: t forView: self];
				[touchData removeObject:w];
				break;
			}
		}
	}
	if ([touchData count] == 0) {
		_id = 0;
	}
}

@end
