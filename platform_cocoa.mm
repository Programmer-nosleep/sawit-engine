#include "platform_cocoa.h"

#include "diagnostics.h"
#include "gl_headers.h"

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

#include <math.h>
#include <string.h>

enum
{
  PLATFORM_KEYCODE_A = 0,
  PLATFORM_KEYCODE_S = 1,
  PLATFORM_KEYCODE_D = 2,
  PLATFORM_KEYCODE_G = 5,
  PLATFORM_KEYCODE_Q = 12,
  PLATFORM_KEYCODE_W = 13,
  PLATFORM_KEYCODE_R = 15,
  PLATFORM_KEYCODE_1 = 18,
  PLATFORM_KEYCODE_2 = 19,
  PLATFORM_KEYCODE_3 = 20,
  PLATFORM_KEYCODE_4 = 21,
  PLATFORM_KEYCODE_P = 35,
  PLATFORM_KEYCODE_SPACE = 49,
  PLATFORM_KEYCODE_ESCAPE = 53,
  PLATFORM_KEYCODE_LEFT_COMMAND = 55,
  PLATFORM_KEYCODE_LEFT_SHIFT = 56,
  PLATFORM_KEYCODE_LEFT_OPTION = 58,
  PLATFORM_KEYCODE_LEFT_CONTROL = 59,
  PLATFORM_KEYCODE_RIGHT_SHIFT = 60,
  PLATFORM_KEYCODE_RIGHT_OPTION = 61,
  PLATFORM_KEYCODE_RIGHT_CONTROL = 62,
  PLATFORM_KEYCODE_F11 = 103,
  PLATFORM_KEYCODE_LEFT_ARROW = 123,
  PLATFORM_KEYCODE_RIGHT_ARROW = 124,
  PLATFORM_KEYCODE_DOWN_ARROW = 125,
  PLATFORM_KEYCODE_UP_ARROW = 126
};

@interface PlatformOpenGLView : NSOpenGLView
@end

@implementation PlatformOpenGLView

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (BOOL)isOpaque
{
  return YES;
}

@end

@interface PlatformWindowDelegate : NSObject <NSWindowDelegate>
{
@public
  PlatformApp* app;
}
@end

@implementation PlatformWindowDelegate

- (BOOL)windowShouldClose:(id)sender
{
  (void)sender;
  if (app != NULL)
  {
    app->running = 0;
  }
  return YES;
}

@end

static int platform_window_has_focus(const PlatformApp* app);
static int platform_is_key_down(const PlatformApp* app, unsigned short key_code);
static void platform_sync_modifier_keys(PlatformApp* app, NSEventModifierFlags modifier_flags);
static void platform_set_mouse_capture(PlatformApp* app, int enabled);
static void platform_toggle_fullscreen(PlatformApp* app);
static void platform_update_dimensions(PlatformApp* app);
static NSTextView* platform_create_overlay_text_view(NSFont* font, NSColor* text_color, NSColor* background_color);
static void platform_layout_native_overlays(PlatformApp* app);
static void platform_update_native_overlays(PlatformApp* app);

static int platform_window_has_focus(const PlatformApp* app)
{
  NSWindow* window = (NSWindow*)app->window;
  return app != NULL && window != nil && [NSApp isActive] && [window isKeyWindow];
}

static int platform_is_key_down(const PlatformApp* app, unsigned short key_code)
{
  return app != NULL && key_code < sizeof(app->key_down) && app->key_down[key_code] != 0;
}

static void platform_sync_modifier_keys(PlatformApp* app, NSEventModifierFlags modifier_flags)
{
  if (app == NULL)
  {
    return;
  }

  app->key_down[PLATFORM_KEYCODE_LEFT_SHIFT] = (modifier_flags & NSEventModifierFlagShift) ? 1U : 0U;
  app->key_down[PLATFORM_KEYCODE_RIGHT_SHIFT] = app->key_down[PLATFORM_KEYCODE_LEFT_SHIFT];
  app->key_down[PLATFORM_KEYCODE_LEFT_CONTROL] = (modifier_flags & NSEventModifierFlagControl) ? 1U : 0U;
  app->key_down[PLATFORM_KEYCODE_RIGHT_CONTROL] = app->key_down[PLATFORM_KEYCODE_LEFT_CONTROL];
  app->key_down[PLATFORM_KEYCODE_LEFT_OPTION] = (modifier_flags & NSEventModifierFlagOption) ? 1U : 0U;
  app->key_down[PLATFORM_KEYCODE_RIGHT_OPTION] = app->key_down[PLATFORM_KEYCODE_LEFT_OPTION];
  app->key_down[PLATFORM_KEYCODE_LEFT_COMMAND] = (modifier_flags & NSEventModifierFlagCommand) ? 1U : 0U;
}

static void platform_set_mouse_capture(PlatformApp* app, int enabled)
{
  if (app == NULL)
  {
    return;
  }

  if (enabled != 0)
  {
    if (app->mouse_captured == 0)
    {
      app->mouse_dx = 0;
      app->mouse_dy = 0;
      app->suppress_next_mouse_delta = 1;
      (void)CGAssociateMouseAndMouseCursorPosition(false);
      if (app->cursor_hidden == 0)
      {
        [NSCursor hide];
        app->cursor_hidden = 1;
      }
      app->mouse_captured = 1;
    }
    return;
  }

  if (app->mouse_captured != 0)
  {
    (void)CGAssociateMouseAndMouseCursorPosition(true);
    if (app->cursor_hidden != 0)
    {
      [NSCursor unhide];
      app->cursor_hidden = 0;
    }
    app->mouse_captured = 0;
  }
}

static void platform_toggle_fullscreen(PlatformApp* app)
{
  NSWindow* window = (NSWindow*)app->window;

  if (window == nil)
  {
    return;
  }

  [window toggleFullScreen:nil];
  app->resized = 1;
}

static void platform_update_dimensions(PlatformApp* app)
{
  NSView* view = (NSView*)app->view;

  if (app == NULL || view == nil)
  {
    return;
  }

  {
    NSRect backing_bounds = [view bounds];
    int new_width = 0;
    int new_height = 0;

    if ([view respondsToSelector:@selector(convertRectToBacking:)])
    {
      backing_bounds = [view convertRectToBacking:backing_bounds];
    }

    new_width = (int)lround(backing_bounds.size.width);
    new_height = (int)lround(backing_bounds.size.height);
    if (new_width < 0)
    {
      new_width = 0;
    }
    if (new_height < 0)
    {
      new_height = 0;
    }

    if (new_width != app->width || new_height != app->height)
    {
      app->width = new_width;
      app->height = new_height;
      app->resized = 1;
      if (app->gl_context != NULL)
      {
        [(NSOpenGLContext*)app->gl_context update];
      }
    }
  }

  platform_layout_native_overlays(app);
}

static NSTextView* platform_create_overlay_text_view(NSFont* font, NSColor* text_color, NSColor* background_color)
{
  NSTextView* text_view = [[NSTextView alloc] initWithFrame:NSZeroRect];

  if (text_view == nil)
  {
    return nil;
  }

  [text_view setEditable:NO];
  [text_view setSelectable:NO];
  [text_view setRichText:NO];
  [text_view setImportsGraphics:NO];
  [text_view setAutomaticQuoteSubstitutionEnabled:NO];
  [text_view setAutomaticDashSubstitutionEnabled:NO];
  [text_view setAutomaticDataDetectionEnabled:NO];
  [text_view setDrawsBackground:YES];
  [text_view setBackgroundColor:background_color];
  [text_view setTextColor:text_color];
  [text_view setFont:font];
  [text_view setVerticallyResizable:NO];
  [text_view setHorizontallyResizable:NO];
  [text_view setTextContainerInset:NSMakeSize(12.0, 10.0)];
  [[text_view textContainer] setLineFragmentPadding:0.0];
  [[text_view textContainer] setWidthTracksTextView:YES];
  [[text_view textContainer] setHeightTracksTextView:YES];
  if ([text_view respondsToSelector:@selector(setUsesAdaptiveColorMappingForDarkAppearance:)])
  {
    [text_view setUsesAdaptiveColorMappingForDarkAppearance:NO];
  }

  return text_view;
}

static void platform_layout_native_overlays(PlatformApp* app)
{
  NSWindow* window = nil;
  NSView* content_view = nil;
  NSTextView* stats_view = nil;
  NSTextView* debug_view = nil;
  NSRect bounds = NSZeroRect;
  const CGFloat margin = 12.0;
  const CGFloat stats_width = 292.0;
  const CGFloat stats_height = 208.0;
  const CGFloat debug_width = 560.0;
  const CGFloat debug_height = 214.0;

  if (app == NULL)
  {
    return;
  }

  window = (NSWindow*)app->window;
  content_view = (window != nil) ? [window contentView] : nil;
  stats_view = (NSTextView*)app->stats_overlay_view;
  debug_view = (NSTextView*)app->debug_overlay_view;
  if (content_view == nil)
  {
    return;
  }

  bounds = [content_view bounds];
  if ((NSView*)app->view != nil)
  {
    [(NSView*)app->view setFrame:bounds];
  }

  if (stats_view != nil)
  {
    [stats_view setFrame:NSMakeRect(
      fmax(margin, bounds.size.width - stats_width - margin),
      fmax(margin, bounds.size.height - stats_height - margin),
      fmin(stats_width, fmax(180.0, bounds.size.width - margin * 2.0)),
      fmin(stats_height, fmax(120.0, bounds.size.height - margin * 2.0))
    )];
  }

  if (debug_view != nil)
  {
    [debug_view setFrame:NSMakeRect(
      fmax(margin, bounds.size.width - debug_width - margin),
      margin,
      fmin(debug_width, fmax(220.0, bounds.size.width - margin * 2.0)),
      fmin(debug_height, fmax(120.0, bounds.size.height * 0.34))
    )];
  }
}

static void platform_update_native_overlays(PlatformApp* app)
{
  NSTextView* stats_view = nil;
  NSTextView* debug_view = nil;

  if (app == NULL)
  {
    return;
  }

  stats_view = (NSTextView*)app->stats_overlay_view;
  debug_view = (NSTextView*)app->debug_overlay_view;

  if (stats_view != nil)
  {
    char stats_text[1024] = { 0 };
    const OverlayMetrics* metrics = &app->overlay.metrics;
    const GpuPreferenceInfo* gpu_info = &app->overlay.gpu_info;
    const float fps = (metrics->frames_per_second > 0.0f) ? metrics->frames_per_second : 0.0f;
    const float frame_ms = (metrics->frame_time_ms > 0.0f) ? metrics->frame_time_ms : 0.0f;
    const char* renderer_name =
      (gpu_info->current_renderer[0] != '\0') ? gpu_info->current_renderer : "OpenGL";

    (void)snprintf(
      stats_text,
      sizeof(stats_text),
      "ENGINE\n"
      "FPS %.0f\n"
      "Frame %.2f ms\n"
      "CPU %.0f%%\n"
      "GPU0 %.0f%%\n"
      "GPU1 %.0f%%\n"
      "Pos %.1f %.1f %.1f\n"
      "Mode %d\n"
      "Block %d\n"
      "Placed %d\n"
      "Target %s\n"
      "Renderer %s",
      fps,
      frame_ms,
      metrics->cpu_usage_percent,
      metrics->gpu0_usage_percent,
      metrics->gpu1_usage_percent,
      metrics->player_position_x,
      metrics->player_position_y,
      metrics->player_position_z,
      metrics->player_mode,
      metrics->selected_block_type,
      metrics->placed_block_count,
      (metrics->target_active != 0) ? "ON" : "OFF",
      renderer_name
    );

    [stats_view setString:[NSString stringWithUTF8String:stats_text]];
  }

  if (debug_view != nil)
  {
    char console_text[8192] = { 0 };
    size_t offset = 0U;
    const int recent_count = diagnostics_get_recent_message_count();
    const int first_index = (recent_count > 10) ? (recent_count - 10) : 0;
    int message_index = 0;

    for (message_index = first_index; message_index < recent_count; ++message_index)
    {
      const char* message = diagnostics_get_recent_message(message_index);
      const int written = snprintf(
        console_text + offset,
        sizeof(console_text) - offset,
        "%s%s",
        (offset > 0U) ? "\n" : "",
        (message != NULL) ? message : ""
      );

      if (written <= 0 || (size_t)written >= sizeof(console_text) - offset)
      {
        break;
      }
      offset += (size_t)written;
    }

    if (offset == 0U)
    {
      (void)snprintf(console_text, sizeof(console_text), "DEBUG CONSOLE\nMenunggu log runtime...");
    }

    [debug_view setString:[NSString stringWithUTF8String:console_text]];
  }
}

int platform_create(PlatformApp* app, const char* title, int width, int height)
{
  @autoreleasepool
  {
    NSApplication* application = nil;
    NSWindow* window = nil;
    NSView* content_view = nil;
    NSOpenGLPixelFormat* pixel_format = nil;
    PlatformOpenGLView* view = nil;
    NSOpenGLContext* context = nil;
    PlatformWindowDelegate* delegate = nil;
    NSTextView* stats_view = nil;
    NSTextView* debug_view = nil;
    NSFont* stats_font = nil;
    NSFont* debug_font = nil;
    NSString* window_title = nil;
    GLint swap_interval = 0;
    NSRect content_rect = NSMakeRect(0.0, 0.0, width, height);
    const NSOpenGLPixelFormatAttribute pixel_attributes[] = {
#if defined(NSOpenGLProfileVersion4_1Core)
      NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core,
#else
      NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
#endif
      NSOpenGLPFAColorSize, 24,
      NSOpenGLPFAAlphaSize, 8,
      NSOpenGLPFADepthSize, 24,
      NSOpenGLPFAAccelerated,
      NSOpenGLPFADoubleBuffer,
      0
    };

    if (app == NULL)
    {
      return 0;
    }

    memset(app, 0, sizeof(*app));
    diagnostics_log("platform_create: cocoa begin");

    application = [NSApplication sharedApplication];
    if (application == nil)
    {
      platform_show_error_message("Cocoa Error", "Failed to create the shared NSApplication instance.");
      return 0;
    }

    [application setActivationPolicy:NSApplicationActivationPolicyRegular];

    window_title = [NSString stringWithUTF8String:(title != NULL) ? title : "OpenGL Sky"];
    if (window_title == nil)
    {
      window_title = @"OpenGL Sky";
    }

    window = [[NSWindow alloc]
      initWithContentRect:content_rect
                styleMask:NSWindowStyleMaskTitled |
                          NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
    if (window == nil)
    {
      platform_show_error_message("Cocoa Error", "Failed to create the macOS window.");
      return 0;
    }

    if ([window respondsToSelector:@selector(setTabbingMode:)])
    {
      [window setTabbingMode:NSWindowTabbingModeDisallowed];
    }

    pixel_format = [[NSOpenGLPixelFormat alloc] initWithAttributes:pixel_attributes];
    if (pixel_format == nil)
    {
      [window release];
      platform_show_error_message("OpenGL Error", "Failed to create the OpenGL pixel format for macOS.");
      return 0;
    }

    view = [[PlatformOpenGLView alloc] initWithFrame:content_rect pixelFormat:pixel_format];
    [pixel_format release];
    if (view == nil)
    {
      [window release];
      platform_show_error_message("OpenGL Error", "Failed to create the OpenGL view for macOS.");
      return 0;
    }

    if ([view respondsToSelector:@selector(setWantsBestResolutionOpenGLSurface:)])
    {
      [view setWantsBestResolutionOpenGLSurface:YES];
    }

    delegate = [[PlatformWindowDelegate alloc] init];
    delegate->app = app;
    [window setDelegate:delegate];
    content_view = [window contentView];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [content_view addSubview:view];
    [window makeFirstResponder:view];
    [window setAcceptsMouseMovedEvents:YES];
    [window setTitle:window_title];
    [window center];
    [window makeKeyAndOrderFront:nil];

    stats_font = [NSFont fontWithName:@"Menlo Bold" size:13.0];
    if (stats_font == nil)
    {
      stats_font = [NSFont monospacedSystemFontOfSize:13.0 weight:NSFontWeightSemibold];
    }
    debug_font = [NSFont fontWithName:@"Menlo" size:11.0];
    if (debug_font == nil)
    {
      debug_font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    }

    stats_view = platform_create_overlay_text_view(
      stats_font,
      [NSColor colorWithCalibratedRed:0.75 green:0.98 blue:0.86 alpha:0.98],
      [NSColor colorWithCalibratedRed:0.03 green:0.04 blue:0.05 alpha:0.82]
    );
    debug_view = platform_create_overlay_text_view(
      debug_font,
      [NSColor colorWithCalibratedRed:0.92 green:0.95 blue:0.99 alpha:0.98],
      [NSColor colorWithCalibratedRed:0.03 green:0.03 blue:0.04 alpha:0.82]
    );
    if (stats_view != nil)
    {
      [content_view addSubview:stats_view];
    }
    if (debug_view != nil)
    {
      [content_view addSubview:debug_view];
    }

    context = [view openGLContext];
    if (context == nil)
    {
      [delegate release];
      [view release];
      [window release];
      platform_show_error_message("OpenGL Error", "Failed to resolve the NSOpenGLContext from the view.");
      return 0;
    }

    [context makeCurrentContext];
    [context setValues:&swap_interval forParameter:NSOpenGLCPSwapInterval];

    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK)
    {
      [delegate release];
      [view release];
      [window release];
      platform_show_error_message("OpenGL Error", "Failed to initialize GLEW for the Cocoa OpenGL context.");
      return 0;
    }
    (void)glGetError();

    app->application = application;
    app->window = window;
    app->view = view;
    app->gl_context = context;
    app->window_delegate = delegate;
    app->stats_overlay_view = stats_view;
    app->debug_overlay_view = debug_view;
    app->timer_start = CFAbsoluteTimeGetCurrent();
    app->running = 1;
    app->resized = 1;
    app->requested_gpu_preference = GPU_PREFERENCE_MODE_AUTO;
    app->overlay.settings = scene_settings_default();
    app->overlay.hot_slider = OVERLAY_SLIDER_NONE;
    app->overlay.active_slider = OVERLAY_SLIDER_NONE;
    app->overlay.hot_toggle = OVERLAY_TOGGLE_NONE;
    app->overlay.hot_gpu_preference = -1;
    app->overlay.god_mode_enabled = 0;
    app->overlay.freeze_time_enabled = 0;
    app->overlay.panel_width = 0;
    app->overlay.panel_collapsed = 1;
    app->overlay.scroll_offset = 0.0f;
    app->overlay.scroll_max = 0.0f;

    platform_update_dimensions(app);
    platform_refresh_gpu_info(app);
    platform_update_native_overlays(app);

    [application finishLaunching];
    [application activateIgnoringOtherApps:YES];
    platform_set_mouse_capture(app, 1);
    diagnostics_logf(
      "platform_create: cocoa success width=%d height=%d gl_version=%s renderer=%s vendor=%s",
      app->width,
      app->height,
      (const char*)glGetString(GL_VERSION),
      (const char*)glGetString(GL_RENDERER),
      (const char*)glGetString(GL_VENDOR));
    return 1;
  }
}

void platform_destroy(PlatformApp* app)
{
  @autoreleasepool
  {
    if (app == NULL)
    {
      return;
    }

    diagnostics_log("platform_destroy: cocoa begin");
    app->running = 0;
    platform_set_mouse_capture(app, 0);

    if (app->stats_overlay_view != NULL)
    {
      [(NSView*)app->stats_overlay_view removeFromSuperview];
      [(NSView*)app->stats_overlay_view release];
      app->stats_overlay_view = NULL;
    }

    if (app->debug_overlay_view != NULL)
    {
      [(NSView*)app->debug_overlay_view removeFromSuperview];
      [(NSView*)app->debug_overlay_view release];
      app->debug_overlay_view = NULL;
    }

    if (app->gl_context != NULL)
    {
      [NSOpenGLContext clearCurrentContext];
      app->gl_context = NULL;
    }

    if (app->window != NULL)
    {
      NSWindow* window = (NSWindow*)app->window;
      [window orderOut:nil];
      [window setDelegate:nil];
      [window release];
      app->window = NULL;
    }

    if (app->view != NULL)
    {
      [(NSView*)app->view release];
      app->view = NULL;
    }

    if (app->window_delegate != NULL)
    {
      [(id)app->window_delegate release];
      app->window_delegate = NULL;
    }

    diagnostics_log("platform_destroy: cocoa end");
  }
}

void platform_pump_messages(PlatformApp* app, PlatformInput* input)
{
  @autoreleasepool
  {
    NSEvent* event = nil;
    unsigned long pressed_mouse_buttons = 0UL;
    int has_focus = 0;
    int alt_down = 0;
    int fullscreen_down = 0;
    int player_mode_down = 0;
    int toggle_cycle_down = 0;
    int reset_cycle_down = 0;
    int increase_speed_down = 0;
    int decrease_speed_down = 0;
    int move_forward_down = 0;
    int move_backward_down = 0;
    int move_left_down = 0;
    int move_right_down = 0;
    int jump_down = 0;
    int move_down_down = 0;
    int fast_modifier_down = 0;

    if (app == NULL || input == NULL)
    {
      return;
    }

    memset(input, 0, sizeof(*input));
    input->selected_block_slot = -1;

    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES]) != nil)
    {
      switch ([event type])
      {
        case NSEventTypeKeyDown:
          if ([event keyCode] < sizeof(app->key_down))
          {
            app->key_down[[event keyCode]] = 1U;
          }
          platform_sync_modifier_keys(app, [event modifierFlags]);
          if ([event keyCode] == PLATFORM_KEYCODE_ESCAPE && [event isARepeat] == NO)
          {
            app->escape_requested = 1;
          }
          if (([event modifierFlags] & NSEventModifierFlagCommand) != 0 &&
            [event keyCode] == PLATFORM_KEYCODE_Q)
          {
            app->running = 0;
          }
          break;

        case NSEventTypeKeyUp:
          if ([event keyCode] < sizeof(app->key_down))
          {
            app->key_down[[event keyCode]] = 0U;
          }
          platform_sync_modifier_keys(app, [event modifierFlags]);
          break;

        case NSEventTypeFlagsChanged:
          platform_sync_modifier_keys(app, [event modifierFlags]);
          break;

        case NSEventTypeLeftMouseDown:
          app->left_button_down = 1;
          if (app->mouse_captured == 0)
          {
            [NSApp sendEvent:event];
          }
          break;

        case NSEventTypeLeftMouseUp:
          app->left_button_down = 0;
          if (app->mouse_captured == 0)
          {
            [NSApp sendEvent:event];
          }
          break;

        case NSEventTypeRightMouseDown:
          app->right_button_down = 1;
          if (app->mouse_captured == 0)
          {
            [NSApp sendEvent:event];
          }
          break;

        case NSEventTypeRightMouseUp:
          app->right_button_down = 0;
          if (app->mouse_captured == 0)
          {
            [NSApp sendEvent:event];
          }
          break;

        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged:
          if (app->mouse_captured != 0 && app->cursor_mode_enabled == 0)
          {
            app->mouse_dx += (int)lround([event deltaX]);
            app->mouse_dy -= (int)lround([event deltaY]);
          }
          else
          {
            [NSApp sendEvent:event];
          }
          break;

        default:
          [NSApp sendEvent:event];
          break;
      }
    }

    platform_update_dimensions(app);
    platform_sync_modifier_keys(app, [NSEvent modifierFlags]);
    has_focus = platform_window_has_focus(app);
    alt_down = has_focus
      ? (platform_is_key_down(app, PLATFORM_KEYCODE_LEFT_OPTION) || platform_is_key_down(app, PLATFORM_KEYCODE_RIGHT_OPTION))
      : 0;
    fullscreen_down = has_focus ? platform_is_key_down(app, PLATFORM_KEYCODE_F11) : 0;
    player_mode_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_G) : 0;
    toggle_cycle_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_P) : 0;
    reset_cycle_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_R) : 0;
    increase_speed_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_UP_ARROW) : 0;
    decrease_speed_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_DOWN_ARROW) : 0;
    move_forward_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_W) : 0;
    move_backward_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_S) : 0;
    move_left_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_A) : 0;
    move_right_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_D) : 0;
    jump_down = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_SPACE) : 0;
    move_down_down = (has_focus && app->cursor_mode_enabled == 0)
      ? (platform_is_key_down(app, PLATFORM_KEYCODE_LEFT_SHIFT) || platform_is_key_down(app, PLATFORM_KEYCODE_RIGHT_SHIFT))
      : 0;
    fast_modifier_down = (has_focus && app->cursor_mode_enabled == 0)
      ? (platform_is_key_down(app, PLATFORM_KEYCODE_LEFT_CONTROL) || platform_is_key_down(app, PLATFORM_KEYCODE_RIGHT_CONTROL))
      : 0;
    pressed_mouse_buttons = [NSEvent pressedMouseButtons];
    app->left_button_down = has_focus ? ((pressed_mouse_buttons & 1UL) != 0UL) : 0;
    app->right_button_down = has_focus ? ((pressed_mouse_buttons & 2UL) != 0UL) : 0;
    app->overlay.cursor_mode_enabled = app->cursor_mode_enabled;
    app->overlay.hot_slider = OVERLAY_SLIDER_NONE;
    app->overlay.active_slider = OVERLAY_SLIDER_NONE;
    app->overlay.hot_toggle = OVERLAY_TOGGLE_NONE;
    app->overlay.hot_gpu_preference = -1;
    app->overlay.panel_width = 0;
    app->overlay.panel_collapsed = 1;
    app->overlay.scroll_offset = 0.0f;
    app->overlay.scroll_max = 0.0f;

    if (has_focus && alt_down && !app->previous_alt_down)
    {
      app->cursor_mode_enabled = (app->cursor_mode_enabled == 0);
      if (app->cursor_mode_enabled != 0)
      {
        platform_set_mouse_capture(app, 0);
      }
      else
      {
        platform_set_mouse_capture(app, 1);
      }
    }

    if (!has_focus)
    {
      platform_set_mouse_capture(app, 0);
    }
    else if (app->cursor_mode_enabled == 0)
    {
      platform_set_mouse_capture(app, 1);
    }

    if (has_focus && fullscreen_down && !app->previous_fullscreen_down)
    {
      platform_toggle_fullscreen(app);
    }

    input->look_x = (float)app->mouse_dx;
    input->look_y = (float)app->mouse_dy;
    if (app->suppress_next_mouse_delta != 0)
    {
      input->look_x = 0.0f;
      input->look_y = 0.0f;
      app->suppress_next_mouse_delta = 0;
    }

    if (app->cursor_mode_enabled != 0)
    {
      input->look_x = 0.0f;
      input->look_y = 0.0f;
    }

    input->move_forward = (float)(move_forward_down - move_backward_down);
    input->move_right = (float)(move_right_down - move_left_down);
    input->escape_pressed = app->escape_requested;
    input->toggle_player_mode_pressed = player_mode_down && !app->previous_player_mode_down;
    input->toggle_cycle_pressed = toggle_cycle_down && !app->previous_toggle_cycle_down;
    input->reset_cycle_pressed = reset_cycle_down && !app->previous_reset_cycle_down;
    input->increase_cycle_speed_pressed = increase_speed_down && !app->previous_increase_speed_down;
    input->decrease_cycle_speed_pressed = decrease_speed_down && !app->previous_decrease_speed_down;
    input->scrub_backward_held = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_LEFT_ARROW) : 0;
    input->scrub_forward_held = (has_focus && app->cursor_mode_enabled == 0) ? platform_is_key_down(app, PLATFORM_KEYCODE_RIGHT_ARROW) : 0;
    input->scrub_fast_held = fast_modifier_down;
    input->move_fast_held = (app->overlay.god_mode_enabled != 0) ? fast_modifier_down : move_down_down;
    input->crouch_held = (app->overlay.god_mode_enabled == 0) ? fast_modifier_down : 0;
    input->jump_pressed = jump_down && !app->previous_jump_down;
    input->jump_held = jump_down;
    input->move_down_held = (app->overlay.god_mode_enabled != 0) ? move_down_down : 0;
    input->remove_block_pressed = (has_focus && app->cursor_mode_enabled == 0) ?
      (app->left_button_down && !app->previous_world_left_button_down) : 0;
    input->place_block_pressed = (has_focus && app->cursor_mode_enabled == 0) ?
      (app->right_button_down && !app->previous_world_right_button_down) : 0;

    if (has_focus && app->cursor_mode_enabled == 0)
    {
      if (platform_is_key_down(app, PLATFORM_KEYCODE_1))
      {
        input->selected_block_slot = 0;
      }
      else if (platform_is_key_down(app, PLATFORM_KEYCODE_2))
      {
        input->selected_block_slot = 1;
      }
      else if (platform_is_key_down(app, PLATFORM_KEYCODE_3))
      {
        input->selected_block_slot = 2;
      }
      else if (platform_is_key_down(app, PLATFORM_KEYCODE_4))
      {
        input->selected_block_slot = 3;
      }
    }

    if (app->cursor_mode_enabled != 0)
    {
      input->move_forward = 0.0f;
      input->move_right = 0.0f;
      input->toggle_player_mode_pressed = 0;
      input->toggle_cycle_pressed = 0;
      input->reset_cycle_pressed = 0;
      input->increase_cycle_speed_pressed = 0;
      input->decrease_cycle_speed_pressed = 0;
      input->scrub_backward_held = 0;
      input->scrub_forward_held = 0;
      input->scrub_fast_held = 0;
      input->move_fast_held = 0;
      input->crouch_held = 0;
      input->jump_pressed = 0;
      input->jump_held = 0;
      input->move_down_held = 0;
      input->remove_block_pressed = 0;
      input->place_block_pressed = 0;
      input->selected_block_slot = -1;
    }

    app->mouse_dx = 0;
    app->mouse_dy = 0;
    app->escape_requested = 0;
    app->previous_player_mode_down = player_mode_down;
    app->previous_toggle_cycle_down = toggle_cycle_down;
    app->previous_reset_cycle_down = reset_cycle_down;
    app->previous_increase_speed_down = increase_speed_down;
    app->previous_decrease_speed_down = decrease_speed_down;
    app->previous_jump_down = jump_down;
    app->previous_alt_down = alt_down;
    app->previous_fullscreen_down = fullscreen_down;
    app->previous_world_left_button_down = app->left_button_down;
    app->previous_world_right_button_down = app->right_button_down;
  }
}

void platform_request_close(PlatformApp* app)
{
  if (app != NULL)
  {
    app->running = 0;
  }
}

float platform_get_time_seconds(const PlatformApp* app)
{
  if (app == NULL)
  {
    return 0.0f;
  }

  return (float)(CFAbsoluteTimeGetCurrent() - app->timer_start);
}

void platform_swap_buffers(const PlatformApp* app)
{
  if (app != NULL && app->gl_context != NULL)
  {
    [(NSOpenGLContext*)app->gl_context flushBuffer];
  }
}

void platform_set_window_title(const PlatformApp* app, const char* title)
{
  @autoreleasepool
  {
    NSWindow* window = (NSWindow*)app->window;
    NSString* window_title = nil;

    if (window == nil)
    {
      return;
    }

    window_title = [NSString stringWithUTF8String:(title != NULL) ? title : "OpenGL Sky"];
    if (window_title == nil)
    {
      window_title = @"OpenGL Sky";
    }
    [window setTitle:window_title];
  }
}

void platform_get_scene_settings(const PlatformApp* app, SceneSettings* out_settings)
{
  if (out_settings == NULL)
  {
    return;
  }

  if (app == NULL)
  {
    *out_settings = scene_settings_default();
    return;
  }

  *out_settings = app->overlay.settings;
}

void platform_set_scene_settings(PlatformApp* app, const SceneSettings* settings)
{
  if (app == NULL || settings == NULL)
  {
    return;
  }

  app->overlay.settings = *settings;
}

int platform_get_god_mode_enabled(const PlatformApp* app)
{
  return (app != NULL && app->overlay.god_mode_enabled != 0);
}

void platform_set_god_mode_enabled(PlatformApp* app, int enabled)
{
  if (app == NULL)
  {
    return;
  }

  app->overlay.god_mode_enabled = (enabled != 0);
}

void platform_update_overlay_metrics(PlatformApp* app, const OverlayMetrics* metrics)
{
  if (app == NULL || metrics == NULL)
  {
    return;
  }

  app->overlay.metrics = *metrics;
  platform_update_native_overlays(app);
}

int platform_consume_gpu_switch_request(PlatformApp* app, GpuPreferenceMode* out_mode)
{
  if (app == NULL || app->gpu_switch_requested == 0)
  {
    return 0;
  }

  if (out_mode != NULL)
  {
    *out_mode = app->requested_gpu_preference;
  }

  app->gpu_switch_requested = 0;
  return 1;
}

void platform_refresh_gpu_info(PlatformApp* app)
{
  if (app == NULL)
  {
    return;
  }

  (void)gpu_preferences_query(&app->overlay.gpu_info);
  gpu_preferences_set_current_renderer(
    &app->overlay.gpu_info,
    (const char*)glGetString(GL_RENDERER),
    (const char*)glGetString(GL_VENDOR));
  platform_update_native_overlays(app);
}

void platform_show_error_message(const char* title, const char* message)
{
  @autoreleasepool
  {
    NSString* alert_title = [NSString stringWithUTF8String:(title != NULL) ? title : "Error"];
    NSString* alert_message = [NSString stringWithUTF8String:(message != NULL) ? message : "Unknown error"];

    diagnostics_logf("%s: %s", (title != NULL) ? title : "Error", (message != NULL) ? message : "Unknown error");

    if (alert_title == nil)
    {
      alert_title = @"Error";
    }
    if (alert_message == nil)
    {
      alert_message = @"Unknown error";
    }

    if ([NSApplication sharedApplication] != nil)
    {
      NSAlert* alert = [[NSAlert alloc] init];
      [alert setMessageText:alert_title];
      [alert setInformativeText:alert_message];
      [alert addButtonWithTitle:@"OK"];
      [alert runModal];
      [alert release];
    }
  }
}
