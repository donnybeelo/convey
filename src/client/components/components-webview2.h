/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/*
 * WebView2 access for Components.NativeWebView. See
 * components-webview2.c.
 *
 * Declared here as well as in Vala so that the C file's definitions are
 * checked against what the Vala side expects to call.
 */

#ifndef CONVEY_WEBVIEW2_H
#define CONVEY_WEBVIEW2_H

#include <glib.h>
#include <gdk/gdk.h>

G_BEGIN_DECLS

typedef struct _ConveyWebView2 ConveyWebView2;

/* Called with the JSON of a message the page posted. */
typedef void (*ConveyWebView2MessageFunc) (const gchar *json,
                                           gpointer user_data);

/* Called with the URI of a link the user activated. */
typedef void (*ConveyWebView2LinkFunc) (const gchar *uri,
                                        gpointer user_data);

/* Called with the PNG of an image the control captured of itself. */
typedef void (*ConveyWebView2CaptureFunc) (const guchar *data,
                                           gsize length,
                                           gpointer user_data);

/* Called when a remote resource the page asked for was not fetched. */
typedef void (*ConveyWebView2BlockedFunc) (gpointer user_data);

gboolean convey_webview2_init (const gchar *user_data_dir,
                               GError **error);

const gchar *convey_webview2_runtime_version (void);

ConveyWebView2 *convey_webview2_new (gpointer parent_hwnd,
                                     gboolean devtools,
                                     ConveyWebView2MessageFunc message_func,
                                     ConveyWebView2LinkFunc link_func,
                                     ConveyWebView2BlockedFunc blocked_func,
                                     gpointer user_data);

void convey_webview2_destroy (ConveyWebView2 *self);

/*
 * Places the view.
 *
 * The first rectangle is the whole of the view, the second the part of
 * it that should be on screen. Both are in the toplevel window's raw
 * pixels.
 */
void convey_webview2_set_geometry (ConveyWebView2 *self,
                                   int x,
                                   int y,
                                   int width,
                                   int height,
                                   int clip_x,
                                   int clip_y,
                                   int clip_width,
                                   int clip_height);

void convey_webview2_set_visible (ConveyWebView2 *self, gboolean visible);

void convey_webview2_set_scale (ConveyWebView2 *self, double scale);

/* Sets what the page's prefers-color-scheme reports. */
void convey_webview2_set_dark_scheme (ConveyWebView2 *self, gboolean dark);

void convey_webview2_set_zoom (ConveyWebView2 *self, double zoom);

void convey_webview2_add_user_script (ConveyWebView2 *self,
                                      const gchar *script);

void convey_webview2_load_html (ConveyWebView2 *self, const gchar *html);

void convey_webview2_post_message (ConveyWebView2 *self, const gchar *json);

void convey_webview2_execute_script (ConveyWebView2 *self,
                                     const gchar *script);

void convey_webview2_set_load_remote (ConveyWebView2 *self,
                                      gboolean load_remote);

/* Asks the control for an image of itself, reported to capture_func. */
void convey_webview2_capture (ConveyWebView2 *self,
                              ConveyWebView2CaptureFunc capture_func);

void convey_webview2_stop (ConveyWebView2 *self);

gpointer convey_webview2_surface_hwnd (GdkSurface *surface);

G_END_DECLS

#endif /* CONVEY_WEBVIEW2_H */
