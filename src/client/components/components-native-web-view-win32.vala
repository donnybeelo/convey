/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

[CCode (cname = "ConveyWebView2MessageFunc", has_target = false)]
private delegate void WebView2MessageFunc(string json, void* user_data);

[CCode (cname = "ConveyWebView2LinkFunc", has_target = false)]
private delegate void WebView2LinkFunc(string uri, void* user_data);

[CCode (cname = "ConveyWebView2BlockedFunc", has_target = false)]
private delegate void WebView2BlockedFunc(void* user_data);

[CCode (cname = "convey_webview2_init")]
private extern bool webview2_init(string user_data_dir) throws GLib.Error;

[CCode (cname = "convey_webview2_runtime_version")]
private extern unowned string? webview2_runtime_version();

[CCode (cname = "convey_webview2_new")]
private extern void* webview2_new(void* parent_hwnd,
                                  bool devtools,
                                  WebView2MessageFunc message_func,
                                  WebView2LinkFunc link_func,
                                  WebView2BlockedFunc blocked_func,
                                  void* user_data);

[CCode (cname = "convey_webview2_destroy")]
private extern void webview2_destroy(void* view);

[CCode (cname = "convey_webview2_set_geometry")]
private extern void webview2_set_geometry(void* view,
                                          int x,
                                          int y,
                                          int width,
                                          int height,
                                          int clip_x,
                                          int clip_y,
                                          int clip_width,
                                          int clip_height);

[CCode (cname = "convey_webview2_set_visible")]
private extern void webview2_set_visible(void* view, bool visible);

[CCode (cname = "convey_webview2_set_scale")]
private extern void webview2_set_scale(void* view, double scale);

[CCode (cname = "convey_webview2_set_zoom")]
private extern void webview2_set_zoom(void* view, double zoom);

[CCode (cname = "convey_webview2_add_user_script")]
private extern void webview2_add_user_script(void* view, string script);

[CCode (cname = "convey_webview2_load_html")]
private extern void webview2_load_html(void* view, string html);

[CCode (cname = "convey_webview2_post_message")]
private extern void webview2_post_message(void* view, string json);

[CCode (cname = "convey_webview2_execute_script")]
private extern void webview2_execute_script(void* view, string script);

[CCode (cname = "convey_webview2_set_load_remote")]
private extern void webview2_set_load_remote(void* view, bool load_remote);

[CCode (cname = "convey_webview2_stop")]
private extern void webview2_stop(void* view);

[CCode (cname = "convey_webview2_surface_hwnd")]
private extern void* webview2_surface_hwnd(Gdk.Surface surface);


/**
 * Windows implementation of the platform's native web view.
 *
 * Hosts a WebView2 (Microsoft Edge) control, which the C shim in
 * components-webview2.c drives over COM. See
 * components-native-web-view-webkit.vala for the contract this
 * implements, and src/client/meson.build for how one implementation is
 * chosen per host system.
 *
 * The control is a child window of the toplevel's own window, since GTK4
 * has no native child-widget support. It is positioned from
 * size_allocate and shown or hidden with this widget, but composites
 * above everything GTK draws, so an ancestor cannot clip it: a view
 * scrolled half out of its viewport still paints in full. That is why
 * the conversation viewer wants a single document per thread here rather
 * than one view per message.
 *
 * Where WebKitGTK splits work between the UI process and a web process
 * extension, WebView2 has no in-renderer hook, so the page-side half of
 * the bridge is injected JavaScript. See {@link BOOTSTRAP}: it presents
 * the same `_ConveyWebExtension.send` the page's own scripts call, and
 * dispatches calls from this side to the page's `convey` object, so
 * ui/components-web-view.js needs no Windows-specific handling.
 *
 * Still missing, in rough order of how much they are missed: serving
 * `cid:` and `convey:` resources, which needs those schemes registered
 * on the environment via ICoreWebView2EnvironmentOptions4 and answered
 * from WebResourceRequested, and without which a message's own images do
 * not appear; the context menu, which ContextMenuRequested supplies
 * along with the labels of the engine's own items; find-in-message and
 * printing, which have their own APIs on later interface versions; and
 * the composer's typing attributes, which mean asking the page for
 * queryCommandState.
 *
 * @see Components.NativeWebView (WebKitGTK implementation)
 */
public class Components.NativeWebView : Gtk.Widget {


    // The page-side half of the bridge, in place of the WebKit web
    // process extension. Keep the message names in sync with
    // Components.WebView and web-process-extension.vala.
    private const string BOOTSTRAP = """
(function() {
    var report = function(name, detail) {
        window.chrome.webview.postMessage({ "name": name, "args": [detail] });
    };
    window.addEventListener("error", function(event) {
        report("__page_error__", String(event.message) + " at " +
               String(event.filename) + ":" + String(event.lineno));
    });
    window.addEventListener("unhandledrejection", function(event) {
        report("__page_error__", "unhandled rejection: " +
               String(event.reason));
    });
    document.addEventListener("DOMContentLoaded", function() {
        report("__page_ready__", typeof window.convey);
    });
    // The control is a window of its own, so the wheel never reaches
    // GTK and the surrounding scrolled window would not scroll while the
    // pointer is over a message. Hand the deltas back instead.
    window.addEventListener("wheel", function(event) {
        window.chrome.webview.postMessage({
            "name": "__wheel__",
            "args": [event.deltaX, event.deltaY, event.ctrlKey]
        });
    }, { "passive": true });
    window._ConveyWebExtension = {
        send: function(name, args) {
            window.chrome.webview.postMessage({
                "name": name, "args": Array.from(args)
            });
        }
    };
    window.chrome.webview.addEventListener("message", function(event) {
        var call = event.data;
        var reply = { "id": call.id };
        try {
            var page = window.convey;
            if (page === undefined) {
                throw new Error("Page has no convey object");
            }
            if (call.name === "__enable_remote_load__") {
                reply["return"] = page.loadRemoteResources();
            } else {
                reply["return"] = page[call.name].apply(page, call.args);
            }
        } catch (error) {
            reply["exception"] = {
                "name": String(error.name),
                "message": String(error.message),
                "backtrace_string": String(error.stack)
            };
        }
        if (reply["return"] === undefined) {
            delete reply["return"];
        }
        window.chrome.webview.postMessage(reply);
    });
})();
""";

    // Keep in sync with Components.WebView
    private const string MESSAGE_EXCEPTION = "__exception__";
    private const string MESSAGE_ENABLE_REMOTE_LOAD = "__enable_remote_load__";
    private const string MESSAGE_RETURN_VALUE = "__return__";
    private const string MESSAGE_REMOTE_BLOCKED = "remote_resource_load_blocked";

    // Reported by the bootstrap, not by the page's own scripts.
    private const string PAGE_ERROR = "__page_error__";
    private const string PAGE_WHEEL = "__wheel__";

    // Keep in sync with Components.WebView, whose Ctrl+scroll zoom
    // controller never sees an event over the control.
    private const double ZOOM_FACTOR = 0.1;
    private const double ZOOM_MAX = 2.0;
    private const double ZOOM_MIN = 0.5;

    // How long to wait for the page to answer a call before giving up.
    private const uint CALL_TIMEOUT_SEC = 30;

    private static bool is_available = false;
    private static Application.Configuration? platform_config = null;


    /** Initialises the browser engine for use by the client. */
    public static void init_platform(Application.Configuration config,
                                     GLib.File web_extension_dir) {
        NativeWebView.platform_config = config;
        // Both cache and browsing data live here, as they do on
        // WebKitGTK: a message body has no business storing either, and
        // the default would be beside the executable.
        string user_data_dir = GLib.Path.build_filename(
            GLib.Environment.get_user_cache_dir(), "convey", "webview2"
        );
        try {
            NativeWebView.is_available = webview2_init(user_data_dir);
        } catch (GLib.Error err) {
            warning("No web view is available: %s", err.message);
        }
    }

    /** Returns a label naming the browser engine, for the about dialog. */
    public static string engine_version_label() {
        /// Application runtime information label
        return _("WebView2 version");
    }

    /** Returns the version of the browser engine in use. */
    public static string engine_version() {
        unowned string? version = webview2_runtime_version();
        return version ??
            /// Application runtime information shown when the Microsoft
            /// Edge WebView2 Runtime is not installed.
            _("Not available");
    }

    private static void on_native_message(string json, void* user_data) {
        ((NativeWebView) user_data).handle_native_message(json);
    }

    private static void on_native_link(string uri, void* user_data) {
        ((NativeWebView) user_data).link_clicked(uri);
    }

    private static void on_native_blocked(void* user_data) {
        // Reported the same way the WebKit web process extension
        // reports it, so that Components.WebView needs no per-platform
        // handling of its own.
        ((NativeWebView) user_data).handle_page_message(
            MESSAGE_REMOTE_BLOCKED, null
        );
    }


    /** Emitted when the user clicks a link in the view. */
    public signal void link_clicked(string uri);

    /** Emitted when an internal resource has been served to the view. */
    public signal void internal_resource_served(string name);

    /** Emitted when the text styles at the editing caret change. */
    public signal void typing_attributes_changed();

    /**
     * Emitted when the user asks for a context menu in the view.
     *
     * WebView2 reports this through ContextMenuRequested, which unlike
     * WebKitGTK also exposes the labels of the engine's own items, so the
     * composer's spelling and text-input items can be rebuilt here when
     * this class grows a handler for it.
     */
    public signal bool context_menu_requested(
        Components.WebViewHitTest hit_test, double x, double y
    );

    /** Emitted when the content under the pointer changes. */
    public signal void pointer_target_changed(
        Components.WebViewHitTest hit_test
    );

    /** Emitted when the view starts loading a resource. */
    public signal void resource_started(string uri);

    /** Emitted when a resource the view was loading has finished. */
    public signal void resource_finished(string uri);

    /** The view's zoom level, where 1.0 is unscaled. */
    public double zoom_level { get; set; default = 1.0; }

    /** Determines if the view is editable. */
    public bool editable { get; set; default = false; }


    // The native control, once this widget has been realised.
    private void* native = null;

    // Scripts and styles added before the control exists, and kept
    // afterwards: styles are written into each document as it loads,
    // since WebView2 has no user stylesheets of its own.
    private GLib.GenericArray<string> scripts =
        new GLib.GenericArray<string>();
    private GLib.GenericArray<string> styles =
        new GLib.GenericArray<string>();
    private string? document_font_css = null;
    private string? monospace_font_css = null;

    // Calls sent to the page and still waiting on a reply, by id.
    private Gee.Map<int64?,PendingCall> pending_calls =
        new Gee.HashMap<int64?,PendingCall>();
    private int64 next_call_id = 1;

    private string? body_html = null;

    // Whether remote resources may be loaded, as asked for before the
    // control existed. See send_page_message.
    private bool load_remote_enabled = false;

    // Last bounds handed to the control, so that recalculating them
    // every frame costs nothing when nothing moved.
    private int last_x = -1;
    private int last_y = -1;
    private int last_width = -1;
    private int last_height = -1;
    private int last_clip_x = -1;
    private int last_clip_y = -1;
    private int last_clip_width = -1;
    private int last_clip_height = -1;

    private double last_scale = 0;

    private ulong frame_handler = 0;
    private ulong dialog_handler = 0;


    private class PendingCall {

        public GLib.SourceFunc resume;
        public Components.WebViewResponse? response = null;
        public bool finished = false;
        public uint timeout_id = 0;

        public PendingCall(owned GLib.SourceFunc resume) {
            this.resume = (owned) resume;
        }

    }


    protected NativeWebView(Application.Configuration config,
                            GLib.File? cache_dir = null) {
        Object();
        init_native();
    }

    /**
     * Constructs a view sharing the given view's engine process.
     *
     * WebView2 runs every control of an environment in the same browser
     * process already, and has no per-view settings to share. What it
     * also has no equivalent of is WebKit's shared user content
     * manager, which is how the WebKit implementation gives a related
     * view the scripts and stylesheets of the view it relates to:
     * {@link Components.WebView.with_related_view} adds none of its
     * own, relying on that sharing. So copy them here, or the page
     * would have no `convey` object for the bridge to call.
     */
    protected NativeWebView.with_related_view(Application.Configuration config,
                                              NativeWebView related) {
        Object();
        this.scripts.extend(related.scripts, (script) => script);
        this.styles.extend(related.styles, (style) => style);
        this.document_font_css = related.document_font_css;
        this.monospace_font_css = related.monospace_font_css;
        init_native();
    }

    /** Adds a script to be run on each page loaded by this view. */
    public void add_user_script(string source) {
        this.scripts.add(source);
        if (this.native != null) {
            webview2_add_user_script(this.native, source);
        }
    }

    /** Adds a stylesheet to be applied to each page loaded by this view. */
    public void add_user_stylesheet(string css, bool all_frames = false) {
        // WebView2 has no user stylesheets, so these are written into
        // the document at load time instead. That means they apply to
        // the top frame only, which is what every caller but the user
        // stylesheet asks for in any case.
        this.styles.add(css);
    }

    /** Sets the font used for the view's proportional text. */
    public void apply_document_font(Pango.FontDescription font) {
        // ponytail: takes effect on the next load, unlike WebKit's
        // settings which restyle the current document. Fonts come from
        // desktop settings read before the first message is loaded, so
        // the difference only shows if they are changed while a message
        // is open.
        this.document_font_css = "html, body { %s }".printf(to_css(font));
    }

    /** Sets the font used for the view's monospaced text. */
    public void apply_monospace_font(Pango.FontDescription font) {
        this.monospace_font_css = "pre, code, tt, kbd, samp { %s }".printf(
            to_css(font)
        );
    }

    /** Loads the given HTML into the view. */
    public void load_html(string? body, string? base_uri = null) {
        this.body_html = body;
        if (this.native != null) {
            webview2_load_html(this.native, to_document(body));
        }
    }

    /** Stops any in-progress load. */
    public void stop_loading() {
        if (this.native != null) {
            webview2_stop(this.native);
        }
    }

    /** Determines if the view can display the given content type. */
    public bool can_show_mime_type(string mime_type) {
        return (
            mime_type == "text/html" ||
            mime_type == "text/plain" ||
            mime_type.has_prefix("image/")
        );
    }

    /** Runs an editing command, such as Copy, on the view. */
    public void execute_editing_command(string command) {
        execute_script(
            "document.execCommand(%s)".printf(to_js_string(command))
        );
    }

    /** Runs an editing command with an argument on the view. */
    public void execute_editing_command_with_argument(string command,
                                                      string argument) {
        execute_script(
            "document.execCommand(%s, false, %s)".printf(
                to_js_string(command), to_js_string(argument)
            )
        );
    }

    /** Evaluates JavaScript in the view's page. */
    public async void evaluate_javascript(string script,
                                          int length = -1,
                                          string? world_name = null,
                                          string? source_uri = null,
                                          GLib.Cancellable? cancellable = null)
        throws GLib.Error {
        // ExecuteScript reports its result to a completion handler the
        // shim discards, so like WebKit's evaluate_javascript here, the
        // value is not returned. Callers wanting one use
        // send_page_message.
        execute_script(script);
    }

    /**
     * Calls a method on the page's JavaScript `convey` object.
     *
     * Returns the reply sent by the page, if any.
     */
    public async Components.WebViewResponse? send_page_message(
        string name,
        GLib.Variant? parameters,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        if (name == MESSAGE_ENABLE_REMOTE_LOAD) {
            // Recorded as well as forwarded: this is called before the
            // view is realised when the sender is already trusted, and
            // the control needs to know once it exists.
            this.load_remote_enabled = true;
        }

        if (this.native == null) {
            // No control and so no page to talk to yet. Not an error:
            // callers ask for state changes before the view is
            // realised, and the WebKit implementation queues those in
            // its engine rather than refusing them.
            debug("No web view yet to send %s to", name);
            return null;
        }

        if (name == MESSAGE_ENABLE_REMOTE_LOAD) {
            webview2_set_load_remote(this.native, true);
        }

        int64 id = this.next_call_id++;
        var call = new PendingCall(send_page_message.callback);
        this.pending_calls[id] = call;

        ulong cancelled_handler = 0;
        if (cancellable != null) {
            cancelled_handler = cancellable.connect(() => {
                    // At idle since disconnecting a cancellable handler
                    // from within it deadlocks.
                    GLib.Idle.add(() => {
                            resume_call(id);
                            return GLib.Source.REMOVE;
                        });
                });
        }

        // A message posted before the page has a document is dropped
        // rather than queued, and a page that never loaded never
        // replies, so no call is left waiting indefinitely.
        call.timeout_id = GLib.Timeout.add_seconds(CALL_TIMEOUT_SEC, () => {
                call.timeout_id = 0;
                debug("Web view call %s timed out", name);
                resume_call(id);
                return GLib.Source.REMOVE;
            });

        webview2_post_message(this.native, to_call_json(id, name, parameters));

        yield;

        call.finished = true;
        this.pending_calls.unset(id);
        if (cancellable != null) {
            cancellable.disconnect(cancelled_handler);
            if (cancellable.is_cancelled()) {
                throw new GLib.IOError.CANCELLED(
                    "Web view call %s cancelled", name
                );
            }
        }

        return call.response;
    }

    /** Highlights the given text in the view, returning the match count. */
    public async uint find_text(string text, GLib.Cancellable cancellable)
        throws GLib.IOError.CANCELLED {
        // Needs ICoreWebView2_25's find API, which is newer than the
        // runtime this targets.
        return 0;
    }

    /** Removes any highlights added by {@link find_text}. */
    public void find_finish() {
        // See find_text.
    }

    /** Shows the platform's print dialog for the view's content. */
    public void print_content(Gtk.Window? parent,
                              Gtk.PrintSettings settings) {
        // ICoreWebView2_16.ShowPrintUI shows the engine's own dialog,
        // which ignores the settings gathered here, so wiring it up
        // means teaching the caller to skip its own dialog first.
    }

    /** Determines if the view has the data for a loaded resource. */
    public bool has_resource(string uri) {
        return false;
    }

    /** Returns the data of a resource the view loaded, if it has it. */
    public async GLib.Bytes? get_resource_data(string uri,
                                               GLib.Cancellable? cancellable)
        throws GLib.Error {
        // Needs WebResourceResponseReceived to keep what was fetched.
        return null;
    }

    /** Forgets the data of every resource loaded so far. */
    public void clear_resources() {
        // See get_resource_data.
    }

    /** Returns the text styles applied at the editing caret. */
    public Components.WebViewTypingAttributes get_typing_attributes() {
        // Needs asking the page for queryCommandState, which is a round
        // trip this synchronous call cannot make.
        return 0;
    }

    /**
     * Returns the content of an internal resource, if known.
     *
     * Implemented by {@link Components.WebView}.
     */
    protected virtual Convey.Memory.Buffer? lookup_internal_resource(
        string uri, string path
    ) {
        return null;
    }

    /**
     * Handles a message sent by the page.
     *
     * Implemented by {@link Components.WebView}.
     */
    protected virtual void handle_page_message(string name,
                                               GLib.Variant? parameters) {
        // Noop
    }

    public override void realize() {
        base.realize();
        if (!NativeWebView.is_available) {
            return;
        }

        Gtk.Native? native_widget = get_native();
        Gdk.Surface? surface = (
            native_widget != null ? native_widget.get_surface() : null
        );
        if (surface == null) {
            warning("Web view realised with no surface to host it");
            return;
        }
        debug("Creating %s on window %p",
              get_type().name(), webview2_surface_hwnd(surface));

        this.native = webview2_new(
            webview2_surface_hwnd(surface),
            (NativeWebView.platform_config != null &&
             NativeWebView.platform_config.enable_inspector),
            on_native_message,
            on_native_link,
            on_native_blocked,
            this
        );

        // Bootstrap first: document-created scripts run in the order
        // they were added, and it installs the error reporting and the
        // `_ConveyWebExtension` object the page's own scripts expect to
        // find already there.
        webview2_add_user_script(this.native, BOOTSTRAP);
        for (int i = 0; i < this.scripts.length; i++) {
            webview2_add_user_script(this.native, this.scripts[i]);
        }
        webview2_set_zoom(this.native, this.zoom_level);
        if (this.load_remote_enabled) {
            webview2_set_load_remote(this.native, true);
        }
        update_bounds();
        webview2_set_visible(this.native, get_mapped());
        if (this.body_html != null) {
            webview2_load_html(this.native, to_document(this.body_html));
        }
    }

    public override void unrealize() {
        if (this.native != null) {
            webview2_destroy(this.native);
            this.native = null;
        }
        base.unrealize();
    }

    public override void map() {
        base.map();

        // Follow the widget's geometry every frame rather than only on
        // allocation: GTK skips size_allocate when a widget keeps its
        // size and merely moves, which is what happens when an info bar
        // appears above the body or the conversation is scrolled. The
        // control is not in GTK's scene graph, so nothing else would
        // move it, and it would sit over whatever took its old place.
        Gdk.FrameClock? clock = get_frame_clock();
        if (clock != null) {
            this.frame_handler = clock.after_paint.connect(() => update_bounds());
        }

        // A dialog is drawn inside the window rather than in one of its
        // own, so the control would sit on top of it. Nothing can put a
        // window of another process's making behind what GTK draws, so
        // take the control away while a dialog is up.
        Adw.Window? window = get_root() as Adw.Window;
        Adw.ApplicationWindow? app_window = (
            get_root() as Adw.ApplicationWindow
        );
        if (window != null) {
            this.dialog_handler = window.notify["visible-dialog"].connect(
                () => update_visibility()
            );
        } else if (app_window != null) {
            this.dialog_handler = app_window.notify["visible-dialog"].connect(
                () => update_visibility()
            );
        }

        if (this.native != null) {
            update_bounds();
            update_visibility();
        }
    }

    /** Shows the control, unless something is drawn over where it is. */
    private void update_visibility() {
        if (this.native == null) {
            return;
        }
        Gtk.Root? root = get_root();
        var window = root as Adw.Window;
        var app_window = root as Adw.ApplicationWindow;
        bool dialog_shown = (
            (window != null && window.visible_dialog != null) ||
            (app_window != null && app_window.visible_dialog != null)
        );
        webview2_set_visible(this.native, get_mapped() && !dialog_shown);
    }

    public override void unmap() {
        if (this.dialog_handler != 0) {
            Gtk.Root? root = get_root();
            if (root != null) {
                GLib.SignalHandler.disconnect(root, this.dialog_handler);
            }
            this.dialog_handler = 0;
        }
        if (this.frame_handler != 0) {
            Gdk.FrameClock? clock = get_frame_clock();
            if (clock != null) {
                clock.disconnect(this.frame_handler);
            }
            this.frame_handler = 0;
        }
        if (this.native != null) {
            webview2_set_visible(this.native, false);
        }
        base.unmap();
    }

    public override void size_allocate(int width, int height, int baseline) {
        base.size_allocate(width, height, baseline);
        update_bounds();
    }

    private void init_native() {
        if (!NativeWebView.is_available) {
            init_placeholder();
        }
        // Deliberately no layout manager otherwise: GTK asks a widget's
        // layout manager to measure and allocate in preference to the
        // widget's own vfuncs, so one here would silently replace both
        // this class's size_allocate and the measure that
        // Components.WebView's subclasses use to size themselves from
        // their content, leaving the control nothing to paint in.
        notify["zoom-level"].connect(() => {
                if (this.native != null) {
                    webview2_set_zoom(this.native, this.zoom_level);
                }
            });
    }

    /**
     * Places the control over the area this widget was given.
     *
     * The control is a sibling of nothing GTK knows about, so its
     * geometry is this widget's, translated into the toplevel's own
     * coordinates and scaled to the physical pixels Windows positions
     * windows in.
     */
    private void update_bounds() {
        Gtk.Native? native_widget = get_native();
        if (this.native == null || native_widget == null) {
            return;
        }

        Graphene.Rect bounds;
        if (!compute_bounds((Gtk.Widget) native_widget, out bounds)) {
            return;
        }

        double offset_x, offset_y;
        native_widget.get_surface_transform(out offset_x, out offset_y);

        // The surface's own scale rather than the widget's integer one,
        // so that a fractionally-scaled monitor still places the control
        // exactly and the page lays out in a viewport the size of the
        // allocation. The control is told the same scale, so that a CSS
        // pixel is one of GTK's logical pixels.
        Gdk.Surface? surface = native_widget.get_surface();
        double scale = surface != null ? surface.get_scale() : 1.0;
        if (scale != this.last_scale) {
            this.last_scale = scale;
            webview2_set_scale(this.native, scale);
        }
        // What is on screen of the view, which is what an ancestor that
        // scrolls would have clipped it to. The control is a window, so
        // GTK cannot clip it; the shim sizes its host window to this and
        // leaves the content where it is, showing the right part.
        Graphene.Rect clip = bounds;
        Gtk.Widget? scroller = find_scrolled_window();
        if (scroller != null) {
            Graphene.Rect scroller_bounds = {};
            if (scroller.compute_bounds((Gtk.Widget) native_widget,
                                        out scroller_bounds)) {
                Graphene.Rect visible = {};
                clip = (
                    clip.intersection(scroller_bounds, out visible)
                    ? visible
                    : Graphene.Rect().init(0, 0, 0, 0)
                );
            }
        }

        int x = (int) ((offset_x + bounds.origin.x) * scale);
        int y = (int) ((offset_y + bounds.origin.y) * scale);
        int width = (int) (bounds.size.width * scale);
        int height = (int) (bounds.size.height * scale);
        int clip_x = (int) ((offset_x + clip.origin.x) * scale);
        int clip_y = (int) ((offset_y + clip.origin.y) * scale);
        int clip_width = (int) (clip.size.width * scale);
        int clip_height = (int) (clip.size.height * scale);
        if (x == this.last_x && y == this.last_y &&
            width == this.last_width && height == this.last_height &&
            clip_x == this.last_clip_x && clip_y == this.last_clip_y &&
            clip_width == this.last_clip_width &&
            clip_height == this.last_clip_height) {
            return;
        }
        this.last_x = x;
        this.last_y = y;
        this.last_width = width;
        this.last_height = height;
        this.last_clip_x = clip_x;
        this.last_clip_y = clip_y;
        this.last_clip_width = clip_width;
        this.last_clip_height = clip_height;
        webview2_set_geometry(
            this.native, x, y, width, height,
            clip_x, clip_y, clip_width, clip_height
        );
    }

    /**
     * Applies a wheel event the page forwarded from the control.
     *
     * The control is a window of its own, so GTK sees no pointer events
     * over it: neither the scrolled window around the conversation nor
     * the view's own Ctrl+scroll zoom would react while the pointer is
     * over a message body.
     */
    private void handle_wheel(double delta_x, double delta_y, bool control) {
        if (control) {
            double zoom = this.zoom_level;
            zoom += (delta_y < 0 ? zoom * ZOOM_FACTOR : -zoom * ZOOM_FACTOR);
            zoom = double.min(double.max(zoom, ZOOM_MIN), ZOOM_MAX);
            if (zoom != this.zoom_level) {
                this.zoom_level = zoom;
                // The height the page reports is unzoomed, so the
                // widget's preferred height depends on this too.
                notify_property("preferred-height");
            }
            return;
        }

        Gtk.ScrolledWindow? scroller = find_scrolled_window();
        if (scroller == null) {
            return;
        }

        scroll_by(scroller.get_vadjustment(), delta_y);
        scroll_by(scroller.get_hadjustment(), delta_x);
    }

    /** Returns the nearest ancestor that scrolls this view, if any. */
    private Gtk.ScrolledWindow? find_scrolled_window() {
        Gtk.ScrolledWindow? scroller = null;
        for (Gtk.Widget? parent = get_parent();
             parent != null && scroller == null;
             parent = parent.get_parent()) {
            scroller = parent as Gtk.ScrolledWindow;
        }
        return scroller;
    }

    private static void scroll_by(Gtk.Adjustment? adjustment, double delta) {
        if (adjustment == null || delta == 0) {
            return;
        }
        // The deltas are already in the page's pixels, which the control
        // has been told are the same as GTK's.
        adjustment.value = double.min(
            adjustment.value + delta,
            adjustment.upper - adjustment.page_size
        );
    }

    private void execute_script(string script) {
        if (this.native != null) {
            webview2_execute_script(this.native, script);
        }
    }

    /**
     * Handles a message the page posted.
     *
     * A message carrying an id is the reply to a call made by {@link
     * send_page_message}; anything else is the page calling out on its
     * own, as ui/components-web-view.js does to report its state.
     */
    private void handle_native_message(string json) {
        Json.Object? message = null;
        try {
            var parser = new Json.Parser();
            parser.load_from_data(json);
            Json.Node? root = parser.get_root();
            if (root != null && root.get_node_type() == OBJECT) {
                message = root.get_object();
            }
        } catch (GLib.Error err) {
            warning("Malformed message from page: %s", err.message);
        }
        if (message == null) {
            return;
        }

        try {
            if (message.has_member("id")) {
                handle_call_reply(message);
            } else if (message.get_string_member("name") == PAGE_WHEEL) {
                Json.Array args = message.get_array_member("args");
                handle_wheel(
                    args.get_double_element(0),
                    args.get_double_element(1),
                    args.get_boolean_element(2)
                );
            } else if (message.get_string_member("name") == PAGE_ERROR) {
                // WebView2 has no console to read, so the page reports
                // what it throws over the bridge instead.
                warning("Page error in %s: %s",
                        get_type().name(),
                        message.get_array_member("args").get_string_element(0));
            } else if (message.has_member("name")) {
                handle_page_message(
                    message.get_string_member("name"),
                    to_message_parameters(message)
                );
            }
        } catch (Util.JS.Error err) {
            warning("Unsupported value from page: %s", err.message);
        }
    }

    private void handle_call_reply(Json.Object message) throws Util.JS.Error {
        int64 id = message.get_int_member("id");
        PendingCall? call = this.pending_calls[id];
        if (call == null) {
            return;
        }

        if (message.has_member("exception")) {
            call.response = new Components.WebViewResponse(
                MESSAGE_EXCEPTION,
                Util.JS.json_to_variant(message.get_member("exception"))
            );
        } else {
            call.response = new Components.WebViewResponse(
                MESSAGE_RETURN_VALUE,
                message.has_member("return")
                    ? Util.JS.json_to_variant(message.get_member("return"))
                    : null
            );
        }
        resume_call(id);
    }

    private void resume_call(int64 id) {
        PendingCall? call = this.pending_calls[id];
        if (call != null && !call.finished) {
            call.finished = true;
            if (call.timeout_id != 0) {
                GLib.Source.remove(call.timeout_id);
                call.timeout_id = 0;
            }
            call.resume();
        }
    }

    /**
     * Converts the arguments of a page message to call parameters.
     *
     * Matches what the WebKit web process extension sends: a lone
     * argument is passed as itself rather than as a one-element
     * container, and no arguments at all means no parameters.
     */
    private GLib.Variant? to_message_parameters(Json.Object message)
        throws Util.JS.Error {
        if (!message.has_member("args")) {
            return null;
        }
        Json.Array args = message.get_array_member("args");
        GLib.Variant? parameters = null;
        if (args.get_length() == 1) {
            parameters = Util.JS.json_to_variant(args.get_element(0));
        } else if (args.get_length() > 1) {
            parameters = Util.JS.json_to_variant(message.get_member("args"));
        }
        return parameters;
    }

    /**
     * Builds the JSON for a call to the page.
     *
     * The page applies the arguments to the named method, so a tuple of
     * parameters is spread into the argument list, matching how the
     * WebKit web process extension unpacks a container.
     */
    private string to_call_json(int64 id,
                                string name,
                                GLib.Variant? parameters) {
        var args = new Json.Array();
        try {
            if (parameters != null) {
                if (parameters.classify() == TUPLE) {
                    for (size_t i = 0; i < parameters.n_children(); i++) {
                        args.add_element(
                            Util.JS.variant_to_json(
                                parameters.get_child_value(i)
                            )
                        );
                    }
                } else {
                    args.add_element(Util.JS.variant_to_json(parameters));
                }
            }
        } catch (Util.JS.Error err) {
            warning("Unsupported parameter for %s: %s", name, err.message);
        }

        var call = new Json.Object();
        call.set_int_member("id", id);
        call.set_string_member("name", name);
        call.set_array_member("args", args);

        var root = new Json.Node(Json.NodeType.OBJECT);
        root.set_object(call);
        var generator = new Json.Generator();
        generator.set_root(root);
        return generator.to_data(null);
    }

    /**
     * Wraps a message body in the styles this view applies to it.
     *
     * In place of WebKit's user stylesheets and font settings, which
     * WebView2 has no equivalent of. The styles come first so that the
     * document's own rules still win.
     */
    private string to_document(string? body) {
        var document = new GLib.StringBuilder();
        for (int i = 0; i < this.styles.length; i++) {
            document.append("<style>").append(this.styles[i])
                .append("</style>\n");
        }
        if (this.document_font_css != null) {
            document.append("<style>").append(this.document_font_css)
                .append("</style>\n");
        }
        if (this.monospace_font_css != null) {
            document.append("<style>").append(this.monospace_font_css)
                .append("</style>\n");
        }
        document.append(body ?? "");
        return document.str;
    }

    private static string to_css(Pango.FontDescription font) {
        double size = font.get_size();
        if (!font.get_size_is_absolute()) {
            size = size / Pango.SCALE;
        }
        return "font-family: \"%s\"; font-size: %dpt;".printf(
            font.get_family() ?? "sans-serif", (int) size
        );
    }

    /**
     * Renders a string as a JavaScript expression yielding it.
     *
     * Escaped as a URI component and decoded in the page rather than
     * quoted: g_strescape turns non-ASCII bytes into octal escapes,
     * which JavaScript reads as individual characters, mangling
     * anything outside ASCII such as an accented font family name.
     */
    private static string to_js_string(string value) {
        return "decodeURIComponent(\"%s\")".printf(
            GLib.Uri.escape_string(value, "", false)
        );
    }

    private void init_placeholder() {
        add_css_class("convey-web-view-placeholder");
        // Only the placeholder has a child to lay out. See init_native.
        set_layout_manager(new Gtk.BinLayout());
        var label = new Gtk.Label(
            /// Placeholder shown in place of a message body when the
            /// Microsoft Edge WebView2 Runtime is not installed.
            _("Message display needs the Microsoft Edge WebView2 Runtime")
        );
        label.wrap = true;
        label.margin_top = label.margin_bottom = 12;
        label.margin_start = label.margin_end = 12;
        label.add_css_class("dim-label");
        label.set_parent(this);
    }

    ~NativeWebView() {
        var child = get_first_child();
        while (child != null) {
            var next = child.get_next_sibling();
            child.unparent();
            child = next;
        }
    }

}
