/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/*
 * WebView2 (Microsoft Edge) access for Components.NativeWebView.
 *
 * Only built on Windows, where there is no WebKitGTK. See
 * components-native-web-view-win32.vala, which declares these functions
 * and is the only caller.
 *
 * WebView2 is COM, and this file uses its C API rather than the C++ one:
 * the C++ headers rely on __uuidof, which GCC does not implement for
 * Microsoft's MIDL-generated headers, and the SDK ships no import
 * library holding the IID symbols the C API would otherwise need. Using
 * the C API sidesteps both, at the cost of writing vtables out by hand.
 *
 * The runtime is loaded at run time rather than linked: MSYS2's
 * webview2-loader package ships WebView2Loader.dll and the headers but
 * no import library, and a machine without the Edge WebView2 Runtime
 * installed should start Convey and say so rather than fail to launch.
 *
 * ponytail: the control is a child HWND of the window's own HWND, so it
 * composites above everything GTK draws and cannot be clipped by an
 * ancestor. The visual-hosting API (ICoreWebView2CompositionController)
 * is the fix if that becomes a problem, and needs a DirectComposition
 * surface shared with GDK.
 */

#define COBJMACROS

#include <glib.h>
#include <gio/gio.h>

#ifdef G_OS_WIN32

#include <windows.h>
#include <objbase.h>
#include <WebView2.h>

#include <gdk/gdk.h>
#include <gdk/win32/gdkwin32.h>

#include "components-webview2.h"

typedef HRESULT (STDMETHODCALLTYPE *CreateEnvironmentFunc) (
    PCWSTR browser_folder,
    PCWSTR user_data_folder,
    ICoreWebView2EnvironmentOptions *options,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler
);

typedef HRESULT (STDMETHODCALLTYPE *GetVersionFunc) (PCWSTR browser_folder,
                                                     LPWSTR *version);

/*
 * ICoreWebView2Controller3, for pinning the rasterization scale.
 *
 * Written out because the SDK ships no import library defining the IID
 * symbols its C API refers to. Taken from WebView2.h, where the value
 * appears only in the MIDL_INTERFACE attribute the C++ API uses. IIDs
 * are fixed for the life of an interface, so this cannot drift.
 */
static const IID ConveyIID_ICoreWebView2Controller3 = {
  0xf9614724, 0x5d2b, 0x41dc,
  { 0xae, 0xf7, 0x73, 0xd6, 0x2b, 0x51, 0x54, 0x3b }
};

struct _ConveyWebView2 {
  HWND parent;
  ICoreWebView2Controller *controller;
  ICoreWebView2 *core;

  ConveyWebView2MessageFunc message_func;
  ConveyWebView2LinkFunc link_func;
  ConveyWebView2BlockedFunc blocked_func;
  gpointer user_data;

  /* Whether remote resources may be fetched. Off until the user says
     so, which is what keeps tracking images in a message from being
     fetched simply by displaying it. */
  gboolean load_remote;

  /* State set before the controller exists, applied once it does. */
  RECT bounds;
  gboolean visible;
  gboolean devtools;
  double zoom;
  double scale;
  GPtrArray *scripts;
  gchar *html;

  /* Handlers, which outlive this struct if a call is still in flight. */
  GSList *handlers;
};

/*
 * A COM callback object.
 *
 * One layout serves every handler this file implements: they all hold a
 * back pointer to their view and differ only in their Invoke. The view
 * clears that pointer when it goes away, so a callback that arrives
 * afterwards does nothing instead of following a dangling pointer.
 *
 * ponytail: QueryInterface hands back this same object for any
 * interface asked for. That is a lie in general, but the runtime only
 * ever asks a callback for IUnknown or for the one interface it was
 * passed as, and getting it right needs IID constants the SDK does not
 * give C callers.
 */
typedef struct {
  void *lpVtbl;
  LONG ref_count;
  ConveyWebView2 *view;
} ConveyHandler;

static ICoreWebView2Environment *convey_env = NULL;
static GSList *convey_pending_views = NULL;
static gchar *convey_runtime_version = NULL;
static gchar *convey_user_data_dir = NULL;
static gboolean convey_env_started = FALSE;

static void convey_webview2_create_controller (ConveyWebView2 *self);
static void convey_webview2_realise (ConveyWebView2 *self);

/*
 * Pins how many raw pixels the control puts a CSS pixel in.
 *
 * Bounds are given in raw pixels, and by default the control picks its
 * own scale from the monitor's DPI. Where that disagrees with GTK's
 * scale the page lays out in a viewport of a different size than the
 * widget was allocated, so its content overflows the control and it
 * grows scrollbars of its own. Matching GTK's scale means one CSS pixel
 * is one of GTK's logical pixels, which is what the height the page
 * reports back is measured in.
 */
static void
convey_webview2_apply_scale (ConveyWebView2 *self)
{
  ICoreWebView2Controller3 *controller3 = NULL;
  if (self->controller == NULL || self->scale <= 0)
    return;
  if (FAILED (ICoreWebView2Controller_QueryInterface (
          self->controller, &ConveyIID_ICoreWebView2Controller3,
          (void **) &controller3)) || controller3 == NULL)
    {
      /* Runtime predates the interface; the page will be scaled by the
         monitor's DPI and may scroll internally. */
      g_debug ("WebView2 runtime has no rasterization scale control");
      return;
    }

  ICoreWebView2Controller3_put_BoundsMode (
      controller3, COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS
  );
  ICoreWebView2Controller3_put_ShouldDetectMonitorScaleChanges (controller3,
                                                                FALSE);
  ICoreWebView2Controller3_put_RasterizationScale (controller3, self->scale);
  ICoreWebView2Controller3_Release (controller3);
}


/* -- Handler plumbing ------------------------------------------------ */

static HRESULT STDMETHODCALLTYPE
handler_query_interface (void *this_, REFIID riid, void **object)
{
  ConveyHandler *self = (ConveyHandler *) this_;
  *object = this_;
  InterlockedIncrement (&self->ref_count);
  return S_OK;
}

static ULONG STDMETHODCALLTYPE
handler_add_ref (void *this_)
{
  ConveyHandler *self = (ConveyHandler *) this_;
  return InterlockedIncrement (&self->ref_count);
}

static ULONG STDMETHODCALLTYPE
handler_release (void *this_)
{
  ConveyHandler *self = (ConveyHandler *) this_;
  LONG count = InterlockedDecrement (&self->ref_count);
  if (count == 0)
    g_free (self);
  return count;
}

/* Allocates a handler owning one reference, held by its view. */
static ConveyHandler *
handler_new (ConveyWebView2 *view, void *vtbl)
{
  ConveyHandler *handler = g_new0 (ConveyHandler, 1);
  handler->lpVtbl = vtbl;
  handler->ref_count = 1;
  handler->view = view;
  if (view != NULL)
    view->handlers = g_slist_prepend (view->handlers, handler);
  return handler;
}


/* -- Environment ----------------------------------------------------- */

static HRESULT STDMETHODCALLTYPE
environment_completed (void *this_,
                       HRESULT result,
                       ICoreWebView2Environment *environment)
{
  if (FAILED (result) || environment == NULL)
    {
      g_warning ("WebView2 environment creation failed: 0x%lx",
                 (unsigned long) result);
      /* Views stay empty; nothing else to do. */
      g_slist_free (convey_pending_views);
      convey_pending_views = NULL;
      return S_OK;
    }

  convey_env = environment;
  ICoreWebView2Environment_AddRef (convey_env);
  g_debug ("WebView2 environment created");

  GSList *pending = convey_pending_views;
  convey_pending_views = NULL;
  for (GSList *view = pending; view != NULL; view = view->next)
    convey_webview2_create_controller (view->data);
  g_slist_free (pending);

  return S_OK;
}

static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl
environment_completed_vtbl = {
  handler_query_interface,
  handler_add_ref,
  handler_release,
  environment_completed,
};

gboolean
convey_webview2_init (const gchar *user_data_dir,
                      GError **error)
{
  HMODULE loader = LoadLibraryW (L"WebView2Loader.dll");
  if (loader == NULL)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                           "WebView2Loader.dll could not be loaded");
      return FALSE;
    }

  GetVersionFunc get_version = (GetVersionFunc) (void *) GetProcAddress (
      loader, "GetAvailableCoreWebView2BrowserVersionString"
  );
  if (get_version == NULL)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                           "WebView2Loader.dll is missing its exports");
      return FALSE;
    }

  LPWSTR version = NULL;
  HRESULT result = get_version (NULL, &version);
  if (FAILED (result) || version == NULL)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                           "The Microsoft Edge WebView2 Runtime is not "
                           "installed");
      return FALSE;
    }
  convey_runtime_version = g_utf16_to_utf8 ((gunichar2 *) version,
                                            -1, NULL, NULL, NULL);
  CoTaskMemFree (version);

  convey_user_data_dir = g_strdup (user_data_dir);
  return TRUE;
}

const gchar *
convey_webview2_runtime_version (void)
{
  return convey_runtime_version;
}

/*
 * Starts creating the shared environment, once.
 *
 * Deferred until the first view needs it rather than done in init:
 * creating it spins up the browser process, which a run that never
 * shows a message body has no use for.
 */
static void
convey_webview2_start_environment (void)
{
  convey_env_started = TRUE;

  HMODULE loader = GetModuleHandleW (L"WebView2Loader.dll");
  CreateEnvironmentFunc create = (CreateEnvironmentFunc) (void *) GetProcAddress (
      loader, "CreateCoreWebView2EnvironmentWithOptions"
  );
  if (create == NULL)
    {
      g_warning ("WebView2Loader.dll has no environment entry point");
      return;
    }

  gunichar2 *dir = g_utf8_to_utf16 (convey_user_data_dir, -1,
                                    NULL, NULL, NULL);
  ConveyHandler *handler = handler_new (NULL, &environment_completed_vtbl);
  HRESULT result = create (
      NULL,
      (PCWSTR) dir,
      NULL,
      (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *) handler
  );
  if (FAILED (result))
    {
      g_warning ("WebView2 environment could not be requested: 0x%lx",
                 (unsigned long) result);
      handler_release (handler);
    }
  g_free (dir);
}


/* -- Per-view event handlers ----------------------------------------- */

static HRESULT STDMETHODCALLTYPE
web_message_received (void *this_,
                      ICoreWebView2 *sender,
                      ICoreWebView2WebMessageReceivedEventArgs *args)
{
  ConveyHandler *handler = (ConveyHandler *) this_;
  if (handler->view == NULL)
    return S_OK;

  LPWSTR json = NULL;
  if (SUCCEEDED (ICoreWebView2WebMessageReceivedEventArgs_get_WebMessageAsJson (
          args, &json)) && json != NULL)
    {
      gchar *utf8 = g_utf16_to_utf8 ((gunichar2 *) json, -1, NULL, NULL, NULL);
      CoTaskMemFree (json);
      if (utf8 != NULL)
        {
          g_debug ("WebView2 page message: %.200s", utf8);
          handler->view->message_func (utf8, handler->view->user_data);
        }
      g_free (utf8);
    }
  return S_OK;
}

static ICoreWebView2WebMessageReceivedEventHandlerVtbl
web_message_received_vtbl = {
  handler_query_interface,
  handler_add_ref,
  handler_release,
  web_message_received,
};

/*
 * Reports the URI of a navigation and says whether to allow it.
 *
 * Only the documents this class loads itself are allowed. A link the
 * user clicked is reported so the application can open it, and anything
 * else is dropped, so a message body cannot navigate the view away from
 * itself.
 *
 * Decided by scheme rather than by remembering that a load was asked
 * for: NavigateToString navigates to about:blank, and so does the
 * control on its own when it starts up, so a flag set before ours is as
 * likely to be spent by that one, cancelling the load and leaving the
 * body empty. Links never use these schemes.
 */
static gboolean
allow_navigation (ConveyWebView2 *view, LPWSTR uri)
{
  gchar *utf8 = (uri != NULL
                 ? g_utf16_to_utf8 ((gunichar2 *) uri, -1, NULL, NULL, NULL)
                 : NULL);
  if (utf8 == NULL ||
      g_ascii_strncasecmp (utf8, "about:", 6) == 0 ||
      g_ascii_strncasecmp (utf8, "data:", 5) == 0)
    {
      g_free (utf8);
      return TRUE;
    }

  view->link_func (utf8, view->user_data);
  g_free (utf8);
  return FALSE;
}

static HRESULT STDMETHODCALLTYPE
navigation_starting (void *this_,
                     ICoreWebView2 *sender,
                     ICoreWebView2NavigationStartingEventArgs *args)
{
  ConveyHandler *handler = (ConveyHandler *) this_;
  if (handler->view == NULL)
    return S_OK;

  LPWSTR uri = NULL;
  ICoreWebView2NavigationStartingEventArgs_get_Uri (args, &uri);
  if (!allow_navigation (handler->view, uri))
    ICoreWebView2NavigationStartingEventArgs_put_Cancel (args, TRUE);
  if (uri != NULL)
    CoTaskMemFree (uri);
  return S_OK;
}

static ICoreWebView2NavigationStartingEventHandlerVtbl
navigation_starting_vtbl = {
  handler_query_interface,
  handler_add_ref,
  handler_release,
  navigation_starting,
};

static HRESULT STDMETHODCALLTYPE
new_window_requested (void *this_,
                      ICoreWebView2 *sender,
                      ICoreWebView2NewWindowRequestedEventArgs *args)
{
  ConveyHandler *handler = (ConveyHandler *) this_;
  if (handler->view == NULL)
    return S_OK;

  /* A link with target="_blank" arrives here rather than as a
     navigation. Never open a window; report it like any other link. */
  LPWSTR uri = NULL;
  ICoreWebView2NewWindowRequestedEventArgs_get_Uri (args, &uri);
  if (uri != NULL)
    {
      gchar *utf8 = g_utf16_to_utf8 ((gunichar2 *) uri, -1, NULL, NULL, NULL);
      if (utf8 != NULL)
        handler->view->link_func (utf8, handler->view->user_data);
      g_free (utf8);
      CoTaskMemFree (uri);
    }
  ICoreWebView2NewWindowRequestedEventArgs_put_Handled (args, TRUE);
  return S_OK;
}

static ICoreWebView2NewWindowRequestedEventHandlerVtbl
new_window_requested_vtbl = {
  handler_query_interface,
  handler_add_ref,
  handler_release,
  new_window_requested,
};

/*
 * Determines if a resource the page asked for may be fetched.
 *
 * The counterpart of the WebKit web process extension's send-request
 * filter: internally-served and self-contained resources always load,
 * and anything remote loads only once the user has allowed it.
 */
static gboolean
allow_resource (ConveyWebView2 *view, const gchar *uri)
{
  static const gchar *ALLOWED_SCHEMES[] = {
    "cid:", "convey:", "data:", "blob:", "about:"
  };
  for (gsize i = 0; i < G_N_ELEMENTS (ALLOWED_SCHEMES); i++)
    {
      if (g_ascii_strncasecmp (uri, ALLOWED_SCHEMES[i],
                               strlen (ALLOWED_SCHEMES[i])) == 0)
        return TRUE;
    }
  return view->load_remote;
}

static HRESULT STDMETHODCALLTYPE
web_resource_requested (void *this_,
                        ICoreWebView2 *sender,
                        ICoreWebView2WebResourceRequestedEventArgs *args)
{
  ConveyHandler *handler = (ConveyHandler *) this_;
  if (handler->view == NULL || convey_env == NULL)
    return S_OK;

  ICoreWebView2WebResourceRequest *request = NULL;
  if (FAILED (ICoreWebView2WebResourceRequestedEventArgs_get_Request (
          args, &request)) || request == NULL)
    return S_OK;

  LPWSTR uri = NULL;
  ICoreWebView2WebResourceRequest_get_Uri (request, &uri);
  gchar *utf8 = (uri != NULL
                 ? g_utf16_to_utf8 ((gunichar2 *) uri, -1, NULL, NULL, NULL)
                 : NULL);
  if (uri != NULL)
    CoTaskMemFree (uri);

  if (utf8 != NULL && !allow_resource (handler->view, utf8))
    {
      ICoreWebView2WebResourceResponse *response = NULL;
      if (SUCCEEDED (ICoreWebView2Environment_CreateWebResourceResponse (
              convey_env, NULL, 403, L"Blocked", L"", &response)))
        {
          ICoreWebView2WebResourceRequestedEventArgs_put_Response (args,
                                                                   response);
          ICoreWebView2WebResourceResponse_Release (response);
        }
      handler->view->blocked_func (handler->view->user_data);
    }

  g_free (utf8);
  ICoreWebView2WebResourceRequest_Release (request);
  return S_OK;
}

static ICoreWebView2WebResourceRequestedEventHandlerVtbl
web_resource_requested_vtbl = {
  handler_query_interface,
  handler_add_ref,
  handler_release,
  web_resource_requested,
};

/*
 * A completion handler that does nothing.
 *
 * AddScriptToExecuteOnDocumentCreated and ExecuteScript both take one,
 * and neither has anything to report that is acted on here. Static, so
 * its reference counting is inert.
 */
static HRESULT STDMETHODCALLTYPE
ignore_completion (void *this_, HRESULT result, LPCWSTR value)
{
  return S_OK;
}

static ULONG STDMETHODCALLTYPE
ignore_add_ref (void *this_)
{
  return 1;
}

static ULONG STDMETHODCALLTYPE
ignore_release (void *this_)
{
  return 1;
}

static HRESULT STDMETHODCALLTYPE
ignore_query_interface (void *this_, REFIID riid, void **object)
{
  *object = this_;
  return S_OK;
}

static ICoreWebView2ExecuteScriptCompletedHandlerVtbl ignore_completed_vtbl = {
  ignore_query_interface,
  ignore_add_ref,
  ignore_release,
  ignore_completion,
};

static struct { void *lpVtbl; } ignore_completed = {
  &ignore_completed_vtbl
};


/* -- Controller ------------------------------------------------------ */

static void
apply_script (ConveyWebView2 *self, const gchar *script)
{
  gunichar2 *wide = g_utf8_to_utf16 (script, -1, NULL, NULL, NULL);
  if (wide != NULL)
    ICoreWebView2_AddScriptToExecuteOnDocumentCreated (
        self->core, (LPCWSTR) wide,
        (ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *)
        &ignore_completed
    );
  g_free (wide);
}

static HRESULT STDMETHODCALLTYPE
controller_completed (void *this_,
                      HRESULT result,
                      ICoreWebView2Controller *controller)
{
  ConveyHandler *handler = (ConveyHandler *) this_;
  if (handler->view == NULL)
    return S_OK;
  if (FAILED (result) || controller == NULL)
    {
      g_warning ("WebView2 controller creation failed: 0x%lx",
                 (unsigned long) result);
      return S_OK;
    }

  ConveyWebView2 *self = handler->view;
  self->controller = controller;
  ICoreWebView2Controller_AddRef (controller);
  ICoreWebView2Controller_get_CoreWebView2 (controller, &self->core);

  ICoreWebView2Settings *settings = NULL;
  if (SUCCEEDED (ICoreWebView2_get_Settings (self->core, &settings)))
    {
      ICoreWebView2Settings_put_IsScriptEnabled (settings, TRUE);
      ICoreWebView2Settings_put_IsWebMessageEnabled (settings, TRUE);
      ICoreWebView2Settings_put_AreHostObjectsAllowed (settings, FALSE);
      ICoreWebView2Settings_put_AreDefaultScriptDialogsEnabled (settings, FALSE);
      ICoreWebView2Settings_put_IsStatusBarEnabled (settings, FALSE);
      ICoreWebView2Settings_put_IsBuiltInErrorPageEnabled (settings, FALSE);
      ICoreWebView2Settings_put_AreDevToolsEnabled (settings, self->devtools);
      /* Ctrl+wheel is forwarded to the client, which zooms the view as a
         whole and resizes it to the content. Letting the control zoom
         itself as well would desynchronise the two. */
      ICoreWebView2Settings_put_IsZoomControlEnabled (settings, FALSE);
      ICoreWebView2Settings_Release (settings);
    }

  EventRegistrationToken token;
  ICoreWebView2_add_WebMessageReceived (
      self->core,
      (ICoreWebView2WebMessageReceivedEventHandler *)
      handler_new (self, &web_message_received_vtbl),
      &token
  );
  ICoreWebView2_add_NavigationStarting (
      self->core,
      (ICoreWebView2NavigationStartingEventHandler *)
      handler_new (self, &navigation_starting_vtbl),
      &token
  );
  ICoreWebView2_add_NewWindowRequested (
      self->core,
      (ICoreWebView2NewWindowRequestedEventHandler *)
      handler_new (self, &new_window_requested_vtbl),
      &token
  );
  ICoreWebView2_AddWebResourceRequestedFilter (
      self->core, L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL
  );
  ICoreWebView2_add_WebResourceRequested (
      self->core,
      (ICoreWebView2WebResourceRequestedEventHandler *)
      handler_new (self, &web_resource_requested_vtbl),
      &token
  );

  for (guint i = 0; i < self->scripts->len; i++)
    apply_script (self, g_ptr_array_index (self->scripts, i));

  convey_webview2_apply_scale (self);
  ICoreWebView2Controller_put_Bounds (controller, self->bounds);
  ICoreWebView2Controller_put_IsVisible (controller, self->visible);
  ICoreWebView2Controller_put_ZoomFactor (controller, self->zoom);

  g_debug ("WebView2 controller created: bounds %ld,%ld %ldx%ld, visible %d",
           (long) self->bounds.left, (long) self->bounds.top,
           (long) (self->bounds.right - self->bounds.left),
           (long) (self->bounds.bottom - self->bounds.top),
           self->visible);

  if (self->html != NULL)
    {
      gchar *html = g_steal_pointer (&self->html);
      convey_webview2_load_html (self, html);
      g_free (html);
    }

  return S_OK;
}

static ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl
controller_completed_vtbl = {
  handler_query_interface,
  handler_add_ref,
  handler_release,
  controller_completed,
};

static void
convey_webview2_create_controller (ConveyWebView2 *self)
{
  HRESULT result = ICoreWebView2Environment_CreateCoreWebView2Controller (
      convey_env,
      self->parent,
      (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *)
      handler_new (self, &controller_completed_vtbl)
  );
  if (FAILED (result))
    g_warning ("WebView2 controller could not be requested: 0x%lx",
               (unsigned long) result);
}

/* Creates the control, or queues the view until the environment is up. */
static void
convey_webview2_realise (ConveyWebView2 *self)
{
  if (convey_env != NULL)
    convey_webview2_create_controller (self);
  else
    {
      convey_pending_views = g_slist_prepend (convey_pending_views, self);
      if (!convey_env_started)
        convey_webview2_start_environment ();
    }
}


/* -- Public API ------------------------------------------------------ */

ConveyWebView2 *
convey_webview2_new (gpointer parent_hwnd,
                     gboolean devtools,
                     ConveyWebView2MessageFunc message_func,
                     ConveyWebView2LinkFunc link_func,
                     ConveyWebView2BlockedFunc blocked_func,
                     gpointer user_data)
{
  ConveyWebView2 *self = g_new0 (ConveyWebView2, 1);
  self->parent = (HWND) parent_hwnd;
  self->devtools = devtools;
  self->message_func = message_func;
  self->link_func = link_func;
  self->blocked_func = blocked_func;
  self->user_data = user_data;
  self->zoom = 1.0;
  self->scripts = g_ptr_array_new_with_free_func (g_free);
  convey_webview2_realise (self);
  return self;
}

void
convey_webview2_destroy (ConveyWebView2 *self)
{
  convey_pending_views = g_slist_remove (convey_pending_views, self);

  for (GSList *node = self->handlers; node != NULL; node = node->next)
    {
      ConveyHandler *handler = node->data;
      handler->view = NULL;
      handler_release (handler);
    }
  g_slist_free (self->handlers);

  if (self->core != NULL)
    ICoreWebView2_Release (self->core);
  if (self->controller != NULL)
    {
      ICoreWebView2Controller_Close (self->controller);
      ICoreWebView2Controller_Release (self->controller);
    }
  g_ptr_array_unref (self->scripts);
  g_free (self->html);
  g_free (self);
}

void
convey_webview2_set_bounds (ConveyWebView2 *self,
                            int x,
                            int y,
                            int width,
                            int height)
{
  self->bounds.left = x;
  self->bounds.top = y;
  self->bounds.right = x + width;
  self->bounds.bottom = y + height;
  if (self->controller != NULL)
    ICoreWebView2Controller_put_Bounds (self->controller, self->bounds);
}

void
convey_webview2_set_visible (ConveyWebView2 *self,
                             gboolean visible)
{
  self->visible = visible;
  if (self->controller != NULL)
    ICoreWebView2Controller_put_IsVisible (self->controller, visible);
}

void
convey_webview2_set_scale (ConveyWebView2 *self,
                           double scale)
{
  self->scale = scale;
  convey_webview2_apply_scale (self);
}

void
convey_webview2_set_zoom (ConveyWebView2 *self,
                          double zoom)
{
  self->zoom = zoom;
  if (self->controller != NULL)
    ICoreWebView2Controller_put_ZoomFactor (self->controller, zoom);
}

void
convey_webview2_add_user_script (ConveyWebView2 *self,
                                 const gchar *script)
{
  /* Kept as well as applied: they are re-added to any control created
     later, which matters because scripts are added before the control
     exists. */
  g_ptr_array_add (self->scripts, g_strdup (script));
  if (self->core != NULL)
    apply_script (self, script);
}

void
convey_webview2_load_html (ConveyWebView2 *self,
                           const gchar *html)
{
  if (self->core == NULL)
    {
      g_free (self->html);
      self->html = g_strdup (html);
      return;
    }

  /* ponytail: NavigateToString caps the document at 2MB and gives it an
     about:blank origin, so cid: and convey: resources in it cannot be
     served yet. Both are fixed by registering those schemes on the
     environment and answering WebResourceRequested instead. */
  if (strlen (html) > 2 * 1024 * 1024)
    g_warning ("Message body is too large for WebView2 to display");

  gunichar2 *wide = g_utf8_to_utf16 (html, -1, NULL, NULL, NULL);
  if (wide != NULL)
    {
      HRESULT result = ICoreWebView2_NavigateToString (self->core,
                                                       (LPCWSTR) wide);
      g_debug ("WebView2 navigate: %" G_GSIZE_FORMAT " bytes, 0x%lx",
               (gsize) strlen (html), (unsigned long) result);
    }
  g_free (wide);
}

void
convey_webview2_post_message (ConveyWebView2 *self,
                              const gchar *json)
{
  if (self->core == NULL)
    return;
  gunichar2 *wide = g_utf8_to_utf16 (json, -1, NULL, NULL, NULL);
  if (wide != NULL)
    ICoreWebView2_PostWebMessageAsJson (self->core, (LPCWSTR) wide);
  g_free (wide);
}

void
convey_webview2_execute_script (ConveyWebView2 *self,
                                const gchar *script)
{
  if (self->core == NULL)
    return;
  gunichar2 *wide = g_utf8_to_utf16 (script, -1, NULL, NULL, NULL);
  if (wide != NULL)
    ICoreWebView2_ExecuteScript (
        self->core, (LPCWSTR) wide,
        (ICoreWebView2ExecuteScriptCompletedHandler *) &ignore_completed
    );
  g_free (wide);
}

void
convey_webview2_set_load_remote (ConveyWebView2 *self,
                                 gboolean load_remote)
{
  self->load_remote = load_remote;
}

void
convey_webview2_stop (ConveyWebView2 *self)
{
  if (self->core != NULL)
    ICoreWebView2_Stop (self->core);
}

gpointer
convey_webview2_surface_hwnd (GdkSurface *surface)
{
  return (gpointer) gdk_win32_surface_get_handle (surface);
}

#endif /* G_OS_WIN32 */
