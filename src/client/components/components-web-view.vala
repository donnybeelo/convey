/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2016-2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * A reply sent by a web view's page in response to a method call.
 */
public class Components.WebViewResponse : GLib.Object {

    /** The name of the reply message. */
    public string name { get; private set; }

    /** The reply's payload, if any. */
    public GLib.Variant? parameters { get; private set; }

    public WebViewResponse(string name, GLib.Variant? parameters) {
        this.name = name;
        this.parameters = parameters;
    }

}

/**
 * What the pointer was over when a web view was clicked.
 *
 * Engine-independent replacement for WebKit's hit test result, so that
 * the client's context menus and link handling do not depend on the
 * browser engine in use.
 */
public class Components.WebViewHitTest : GLib.Object {

    /** The URI of the link under the pointer, if any. */
    public string? link_uri { get; construct; default = null; }

    /** The text of the link under the pointer, if any. */
    public string? link_label { get; construct; default = null; }

    /** The URI of the image under the pointer, if any. */
    public string? image_uri { get; construct; default = null; }

    /** The URI of the media element under the pointer, if any. */
    public string? media_uri { get; construct; default = null; }

    /** Determines if the pointer was over editable content. */
    public bool is_editable { get; construct; default = false; }

    /** Determines if the pointer was over the current selection. */
    public bool is_selection { get; construct; default = false; }

    /** Determines if the pointer was over a link. */
    public bool is_link {
        get { return this.link_uri != null; }
    }

    /** Determines if the pointer was over an image. */
    public bool is_image {
        get { return this.image_uri != null; }
    }

    public WebViewHitTest(string? link_uri = null,
                          string? link_label = null,
                          string? image_uri = null,
                          string? media_uri = null,
                          bool is_editable = false,
                          bool is_selection = false) {
        Object(
            link_uri: link_uri,
            link_label: link_label,
            image_uri: image_uri,
            media_uri: media_uri,
            is_editable: is_editable,
            is_selection: is_selection
        );
    }

}

/**
 * The text styles applied to text typed at the editing caret.
 */
[Flags]
public enum Components.WebViewTypingAttributes {
    BOLD,
    ITALIC,
    UNDERLINE,
    STRIKETHROUGH;
}

/**
 * Base class for all web view instances used by the Convey client.
 *
 * This provides common functionality expected by the client for
 * displaying HTML, such as common engine settings, desktop font
 * integration, Inspector support, and remote and inline resource
 * handling for content such as images and videos.
 *
 * The underlying browser engine is supplied by {@link
 * Components.NativeWebView}, which is a different implementation on
 * each platform.
 */
public abstract class Components.WebView : Components.NativeWebView, Convey.BaseInterface {


    /** URI Scheme and delimiter for internal resource loads. */
    public const string INTERNAL_URL_PREFIX = "convey:";

    /** URI for internal message body page loads. */
    public const string INTERNAL_URL_BODY = INTERNAL_URL_PREFIX + "body";

    /** URI Scheme and delimiter for resources loaded by Content-ID. */
    public const string CID_URL_PREFIX = "cid:";

    // Editing command names. These are the standard HTML editing
    // command names, and are the same for every browser engine.
    protected const string EDITING_COMMAND_COPY = "Copy";
    protected const string EDITING_COMMAND_CUT = "Cut";
    protected const string EDITING_COMMAND_PASTE = "Paste";
    protected const string EDITING_COMMAND_SELECT_ALL = "SelectAll";

    // Keep these in sync with ConveyWebExtension
    private const string MESSAGE_ENABLE_REMOTE_LOAD = "__enable_remote_load__";
    private const string MESSAGE_EXCEPTION = "__exception__";
    private const string MESSAGE_RETURN_VALUE = "__return__";

    // WebKit message handler names
    private const string COMMAND_STACK_CHANGED = "command_stack_changed";
    private const string CONTENT_LOADED = "content_loaded";
    private const string DOCUMENT_MODIFIED = "document_modified";
    private const string PREFERRED_HEIGHT_CHANGED = "preferred_height_changed";
    private const string REMOTE_RESOURCE_LOAD_BLOCKED = "remote_resource_load_blocked";
    private const string SELECTION_CHANGED = "selection_changed";

    private const double ZOOM_DEFAULT = 1.0;
    private const double ZOOM_FACTOR = 0.1;
    private const double ZOOM_MAX = 2.0;
    private const double ZOOM_MIN = 0.5;

    private const string USER_CSS = "user-style.css";
    private const string USER_CSS_LEGACY = "user-message.css";


    // Scripts and stylesheets injected into every view, as source
    // text. Kept engine-independent so the platform's native view
    // decides how to inject them.
    //
    // Deliberately not given inline initialisers: Vala emits those
    // into class_init, which GObject runs lazily on first
    // instantiation, i.e. after load_resources() has run. An
    // initialiser here silently wipes the loaded resources.
    private static string[] scripts;

    private static string[] styles;

    private static string? user_style;


    /**
     * Loads static resources used by WebView.
     */
    public static void load_resources(GLib.File user_dir)
        throws GLib.Error {
        // Initialize, or overwrite any user scripts/styles we've loaded before
        WebView.scripts = {
            load_app_script("darkreader.js"),
            load_app_script("components-web-view.js")
        };
        WebView.styles = { load_app_stylesheet("components-web-view.css") };
        WebView.user_style = null;

        foreach (string name in new string[] { USER_CSS, USER_CSS_LEGACY }) {
            GLib.File stylesheet = user_dir.get_child(name);
            try {
                WebView.user_style = load_user_stylesheet(stylesheet);
                break;
            } catch (GLib.IOError.NOT_FOUND err) {
                // All good, try the next one or just exit
            } catch (GLib.FileError.NOENT err) {
                // Ditto
            } catch (GLib.Error err) {
                warning(
                    "Could not load %s: %s", stylesheet.get_path(), err.message
                );
            }
        }
    }

    /** Loads an application-specific stylesheet's source. */
    protected static string load_app_stylesheet(string name)
        throws GLib.Error {
        return GioUtil.read_resource(name);
    }

    /** Loads a user stylesheet's source from disk. */
    protected static string load_user_stylesheet(GLib.File name)
        throws GLib.Error {
        return new Convey.Memory.FileBuffer(name, true).get_valid_utf8();
    }

    /** Loads an application-specific JavaScript script's source. */
    protected static string load_app_script(string name)
        throws Error {
        return GioUtil.read_resource(name);
    }

    private static inline double get_text_scale () {
#if HAVE_WEBKIT
        // WebKitGTK (after 2.45.3) reports a height that does not
        // account for font scaling, so apply it here. The setting reads
        // as -1 where nothing provides it, which would scale the height
        // to nothing, so fall back to unscaled.
        int xft_dpi = Gtk.Settings.get_default().gtk_xft_dpi;
        return xft_dpi > 0 ? xft_dpi / 96.0 / 1024.0 : 1.0;
#else
        // Other engines report a height with their own scaling already
        // applied, WebView2 included: it scales the page itself from the
        // monitor's DPI, so scaling again here would double it.
        return 1.0;
#endif
    }

    /**
     * Delegate for message handler callbacks.
     *
     * @see register_message_callback
     */
    protected delegate void MessageCallback(GLib.Variant? parameters);

    // Work around for not being able to put delegates in a Gee collection.
    private class MessageCallable {

        public unowned MessageCallback handler;

        public MessageCallable(MessageCallback handler) {
            this.handler = handler;
        }

    }

    /**
     * Determines if the view's content has been fully loaded.
     *
     * This property is updated immediately before the {@link
     * content_loaded} signal is fired, and is triggered by the
     * PageState JavaScript object completing its load
     * handler. I.e. This will be true after the in-page JavaScript has
     * finished making any modifications to the page content.
     *
     * This will likely be fired after WebKitGTK sets the `is-loading`
     * property to `FALSE` and emits `load-changed` with
     * `WebKitLoadEvent.LOAD_FINISHED`, since they are related to
     * network resource loading, not page content.
     */
    public bool is_content_loaded { get; private set; default = false; }

    /** Determines if the view has any selected text */
    public bool has_selection { get; private set; default = false; }

    /** The HTML content's current preferred height in window pixels. */
    public int preferred_height {
        get {
            return (int) GLib.Math.round(
                this.webkit_reported_height * this.zoom_level
            );
        }
    }

    /**
     * Specifies whether loading remote resources is currently permitted.
     *
     * If false, any remote resources contained in HTML loaded into
     * the view will be blocked.
     *
     * @see load_remote_resources
     */
    public bool is_load_remote_resources_enabled {
        get; private set; default = false;
    }

    public string document_font {
        get {
            return _document_font;
        }
        set {
            _document_font = value;
            apply_document_font(Pango.FontDescription.from_string(value));
        }
    }
    private string _document_font;

    public string monospace_font {
        get {
            return _monospace_font;
        }
        set {
            _monospace_font = value;
            apply_monospace_font(Pango.FontDescription.from_string(value));
        }
    }
    private string _monospace_font;

    private weak string? body = null;

    private Application.Configuration config;

    private Gee.Map<string,Convey.Memory.Buffer> internal_resources =
        new Gee.HashMap<string,Convey.Memory.Buffer>();

    private Gee.Map<string,MessageCallable> message_handlers =
        new Gee.HashMap<string,MessageCallable>();

    private double webkit_reported_height = 0;

    // Accumulated smooth-scroll delta for Ctrl+scroll zoom stepping
    private double zoom_scroll_delta = 0;


    /**
     * Emitted when the view's content has finished loaded.
     *
     * See {@link is_content_loaded} for detail about when this is
     * emitted.
     */
    public signal void content_loaded();

    /** Emitted when the web view's undo/redo stack state changes. */
    public signal void command_stack_changed(bool can_undo, bool can_redo);

    /** Emitted when the web view's content has changed. */
    public signal void document_modified();

    /** Emitted when a user clicks a link in the view. */
    public signal void link_activated(string uri);

    /** Emitted when the view has loaded a resource added to it. */
    public signal void internal_resource_loaded(string name);

    /** Emitted when a remote resource load was disallowed. */
    public signal void remote_resource_load_blocked();


    /**
     * Initialises the browser engine for use by the client.
     */
    public static void init_web_context(Application.Configuration config,
                                        GLib.File web_extension_dir) {
        NativeWebView.init_platform(config, web_extension_dir);
    }

    protected WebView(Application.Configuration config,
                      GLib.File? cache_dir = null) {
        base(config, cache_dir);
        base_ref();

        foreach (string script in WebView.scripts) {
            add_user_script(script);
        }
        foreach (string style in WebView.styles) {
            add_user_stylesheet(style);
        }
        if (WebView.user_style != null) {
            add_user_stylesheet(WebView.user_style, true);
        }

        init(config);
    }

    /**
     * Constructs a new web view sharing another view's engine process.
     *
     * The new view will use the same process, settings and injected
     * content as the given related view's.
     */
    protected WebView.with_related_view(Application.Configuration config,
                                        WebView related) {
        base.with_related_view(config, related);
        base_ref();
        init(config);
    }

    ~WebView() {
        base_unref();
    }

    public override void dispose() {
        this.message_handlers.clear();
        base.dispose();
    }

    /**
     * Loads a message HTML body into the view.
     */
    public new void load_html(string? body, string? base_uri=null) {
        this.body = body;
        // The viewport width will be 0 if the email is loaded before
        // its WebView is laid out in the widget hierarchy. As a workaround, to
        // prevent this causing the email being squished down to is minimum
        // width and hence being stretched right out in height, always load
        // HTML once view is mapped
        if (this.get_mapped()) {
            base.load_html(body, base_uri ?? INTERNAL_URL_BODY);
        } else {
            ulong handler_id = 0;
            handler_id = this.map.connect(() => {
                base.load_html(body, base_uri ?? INTERNAL_URL_BODY);
                if (handler_id > 0) {
                    this.disconnect(handler_id);
                }
            });
        }
    }

    /**
     * Loads a message HTML body into the view.
     */
    public new void load_html_headless(string? body, string? base_uri=null) {
        this.body = body;
        base.load_html(body, base_uri ?? INTERNAL_URL_BODY);
    }

    /**
     * Returns the view's content as an HTML string.
     */
    public async string? get_html() throws Error {
        return yield call_returning<string?>(Util.JS.callable("getHtml"), null);
    }

    /**
     * Adds an resource that may be accessed from the view via a URL.
     *
     * Internal resources may be access via both the internal `convey`
     * scheme (for resources such as an image inserted via the
     * composer) or via the `cid` scheme (for standard HTML email IMG
     * elements).
     */
    public void add_internal_resource(string id, Convey.Memory.Buffer buf) {
        this.internal_resources[id] = buf;
    }

    /**
     * Adds a set of internal resources to the view.
     *
     * @see add_internal_resource
     */
    public void add_internal_resources(Gee.Map<string,Convey.Memory.Buffer> res) {
        this.internal_resources.set_all(res);
    }

    /**
     * Load any remote resources that were previously blocked.
     *
     * Calling this before calling {@link load_html} will enable any
     * remote resources to be loaded as the HTML is loaded. Calling it
     * afterwards wil ensure any remote resources that were blocked
     * during initial HTML page load are now loaded.
     *
     * @see is_load_remote_resources_enabled
     */
    public async void load_remote_resources(GLib.Cancellable? cancellable)
        throws GLib.Error {
        this.is_load_remote_resources_enabled = true;
        yield this.call_void(
            Util.JS.callable(MESSAGE_ENABLE_REMOTE_LOAD), null
        );
    }

    /**
     * Selects all content in the web view.
     */
    public void select_all() {
        execute_editing_command(EDITING_COMMAND_SELECT_ALL);
    }

    /**
     * Copies selected content and sends it to the clipboard.
     */
    public void copy_clipboard() {
        execute_editing_command(EDITING_COMMAND_COPY);
    }

    public void zoom_reset() {
        this.zoom_level = ZOOM_DEFAULT;
        // Notify the preferred height has changed since it depends on
        // the zoom level. Same for zoom in and out below.
        notify_property("preferred-height");
    }

    public void zoom_in() {
        double new_zoom = double.min(
            this.zoom_level + this.zoom_level * ZOOM_FACTOR, ZOOM_MAX
        );
        if (new_zoom == this.zoom_level) {
            return;
        }
        this.zoom_level = new_zoom;
        notify_property("preferred-height");
    }

    public void zoom_out() {
        double new_zoom = double.max(
            this.zoom_level - this.zoom_level * ZOOM_FACTOR, ZOOM_MIN
        );
        if (new_zoom == this.zoom_level) {
            return;
        }
        this.zoom_level = new_zoom;
        notify_property("preferred-height");
    }

    public new async void set_editable(bool enabled,
                                       Cancellable? cancellable)
        throws Error {
        yield call_void(
            Util.JS.callable("setEditable").bool(enabled), cancellable
        );
    }

    /**
     * Invokes a {@link Util.JS.Callable} on this web view.
     *
     * This calls the given callable on the `convey` object for the
     * current view, any returned value are ignored.
     */
    protected async void call_void(Util.JS.Callable target,
                                   GLib.Cancellable? cancellable)
        throws GLib.Error {
        yield call_impl(target, cancellable);
    }

    /**
     * Invokes a {@link Util.JS.Callable} on this web view.
     *
     * This calls the given callable on the `convey` object for the
     * current view. The value returned by the call is returned by
     * this method.
     *
     * The type parameter `T` must match the type returned by the
     * call, else an error is thrown. Only simple nullable value types
     * are supported for T, for more complex return types (arrays,
     * dictionaries, etc) specify {@link GLib.Variant} for `T` and
     * manually parse that.
     */
    protected async T call_returning<T>(Util.JS.Callable target,
                                        GLib.Cancellable? cancellable)
        throws GLib.Error {
        Components.WebViewResponse? response = yield call_impl(
            target, cancellable
        );
        if (response == null) {
            throw new Util.JS.Error.TYPE(
                "Method call %s did not return a value", target.to_string()
            );
        }
        GLib.Variant? param = response.parameters;
        T ret_value = null;
        var ret_type = typeof(T);
        if (ret_type == typeof(GLib.Variant)) {
            ret_value = param;
        } else {
            if (param != null && param.get_type().is_maybe()) {
                param = param.get_maybe();
            }
            if (param != null) {
                // Since these replies are coming from JS via
                // Util.JS.value_to_variant, they will only be one of
                // string, double, bool, array or dict
                var param_type = param.classify();
                if (ret_type == typeof(string) && param_type == STRING) {
                    ret_value = param.get_string();
                } else if (ret_type == typeof(bool) && param_type == BOOLEAN) {
                    ret_value = (bool?) param.get_boolean();
                } else if (ret_type == typeof(int) && param_type == DOUBLE) {
                    ret_value = (int?) ((int) param.get_double());
                } else if (ret_type == typeof(short) && param_type == DOUBLE) {
                    ret_value = (short?) ((short) param.get_double());
                } else if (ret_type == typeof(char) && param_type == DOUBLE) {
                    ret_value = (char?) ((char) param.get_double());
                } else if (ret_type == typeof(long) && param_type == DOUBLE) {
                    ret_value = (long?) ((long) param.get_double());
                } else if (ret_type == typeof(int64) && param_type == DOUBLE) {
                    ret_value = (int64?) ((int64) param.get_double());
                } else if (ret_type == typeof(uint) && param_type == DOUBLE) {
                    ret_value = (uint?) ((uint) param.get_double());
                } else if (ret_type == typeof(uchar) && param_type == DOUBLE) {
                    ret_value = (uchar?) ((uchar) param.get_double());
                } else if (ret_type == typeof(ushort) && param_type == DOUBLE) {
                    ret_value = (ushort?) ((ushort) param.get_double());
                } else if (ret_type == typeof(ulong) && param_type == DOUBLE) {
                    ret_value = (ulong?) ((ulong) param.get_double());
                } else if (ret_type == typeof(uint64) && param_type == DOUBLE) {
                    ret_value = (uint64?) ((uint64) param.get_double());
                } else if (ret_type == typeof(double) && param_type == DOUBLE) {
                    ret_value = (double?) param.get_double();
                } else if (ret_type == typeof(float) && param_type == DOUBLE) {
                    ret_value = (float?) ((float) param.get_double());
                } else {
                    throw new Util.JS.Error.TYPE(
                        "%s is not a supported type for %s",
                        ret_type.name(), param_type.to_string()
                    );
                }
            }
        }
        return ret_value;
    }

    /**
     * Registers a callback for a specific WebKit user message.
     */
    protected void register_message_callback(string name,
                                             MessageCallback handler) {
        this.message_handlers.set(name, new MessageCallable(handler));
    }

    private void init(Application.Configuration config) {
        this.config = config;
        this.link_clicked.connect((uri) => link_activated(uri));
        this.internal_resource_served.connect(
            (name) => internal_resource_loaded(name)
        );

        register_message_callback(
            COMMAND_STACK_CHANGED, on_command_stack_changed
        );
        register_message_callback(
            CONTENT_LOADED, on_content_loaded
        );
        register_message_callback(
            DOCUMENT_MODIFIED, on_document_modified
        );
        register_message_callback(
            PREFERRED_HEIGHT_CHANGED, on_preferred_height_changed
        );
        register_message_callback(
            REMOTE_RESOURCE_LOAD_BLOCKED, on_remote_resource_load_blocked
        );
        register_message_callback(
            SELECTION_CHANGED, on_selection_changed
        );

        config.settings.changed[
            Application.Configuration.UNSET_HTML_COLORS
        ].connect(() => {
                update_unset_html_colors.begin();
            });

        // Load the persisted zoom once, then only write changes back.
        // A bidirectional binding would slave every open message view
        // to a single value, so zooming one message would reflow them
        // all at once (a noticeable stall on large threads). New views
        // still open at the last-used zoom via the initial read.
        this.zoom_level = config.conversation_viewer_zoom;
        if (this.zoom_level < ZOOM_MIN) {
            this.zoom_level = ZOOM_MIN;
        } else if (this.zoom_level > ZOOM_MAX) {
            this.zoom_level = ZOOM_MAX;
        }
        config.bind(
            Application.Configuration.CONVERSATION_VIEWER_ZOOM_KEY,
            this, "zoom_level", GLib.SettingsBindFlags.SET
        );
        var scroll_controller = new Gtk.EventControllerScroll(Gtk.EventControllerScrollFlags.VERTICAL);
        scroll_controller.scroll.connect(on_scroll_event);
        add_controller(scroll_controller);

        // Watch desktop font settings
        Settings system_settings = config.gnome_interface;
        system_settings.bind("document-font-name", this,
                             "document-font", SettingsBindFlags.DEFAULT);
        system_settings.bind("monospace-font-name", this,
                             "monospace-font", SettingsBindFlags.DEFAULT);
    }

    private async void update_unset_html_colors() {
        if (!this.is_content_loaded) {
            return;
        }

        try {
            yield call_void(
                Util.JS.callable("setUnsetHtmlColors").bool(
                    this.config.unset_html_colors
                ),
                null
            );
        } catch (GLib.Error err) {
            warning("Could not update HTML email colors: %s", err.message);
        }
    }

    private async Components.WebViewResponse? call_impl(
        Util.JS.Callable target,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        Components.WebViewResponse? response = yield send_page_message(
            target.get_name(), target.to_parameters(), cancellable
        );
        if (response != null) {
            var response_name = response.name;
            if (response_name == MESSAGE_EXCEPTION) {
                var exception = new GLib.VariantDict(response.parameters);
                var name = exception.lookup_value("name", GLib.VariantType.STRING) as string;
                var message = exception.lookup_value("message", GLib.VariantType.STRING) as string;
                var backtrace = exception.lookup_value("backtrace_string", GLib.VariantType.STRING) as string;
                var source = exception.lookup_value("source_uri", GLib.VariantType.STRING) as string;
                var line = exception.lookup_value("line_number", GLib.VariantType.UINT32);
                var column = exception.lookup_value("column_number", GLib.VariantType.UINT32);

                var log_message = "Method call %s raised %s exception at %s:%d:%d: %s".printf(
                    target.to_string(),
                    name ?? "unknown",
                    source ?? "unknown",
                    (line != null ? (int) line.get_uint32() : -1),
                    (column != null ? (int) column.get_uint32() : -1),
                    message ?? "unknown"
                );
                debug(log_message);
                if (backtrace != null) {
                    debug(backtrace);
                }

                throw new Util.JS.Error.EXCEPTION(log_message);
            } else if (response_name != MESSAGE_RETURN_VALUE) {
                throw new Util.JS.Error.TYPE(
                    "Method call %s returned unknown name: %s",
                    target.to_string(),
                    response_name
                );
            }
        }
        return response;
    }

    protected override Convey.Memory.Buffer? lookup_internal_resource(
        string uri, string path
    ) {
        return (
            uri == INTERNAL_URL_BODY
            ? new Convey.Memory.StringBuffer(this.body)
            : this.internal_resources[path]
        );
    }

    private bool on_scroll_event(Gtk.EventControllerScroll scroll_controller, double dx, double dy) {
        var event = (Gdk.ScrollEvent) scroll_controller.get_current_event();
        if (Gdk.ModifierType.CONTROL_MASK in event.get_modifier_state()) {
            if (event.get_direction() == Gdk.ScrollDirection.UP) {
                zoom_in();
                return true;
            } else if (event.get_direction() == Gdk.ScrollDirection.DOWN) {
                zoom_out();
                return true;
            } else if (event.get_direction() == Gdk.ScrollDirection.SMOOTH) {
                // Touchpads emit many tiny deltas per gesture. Zooming
                // on each one floods WebKit with reflows and feels
                // laggy, so accumulate and zoom in discrete steps
                // (one per wheel-notch worth of scrolling).
                double delta_x, delta_y;
                event.get_deltas(out delta_x, out delta_y);
                this.zoom_scroll_delta += delta_y;
                while (this.zoom_scroll_delta <= -1.0) {
                    zoom_in();
                    this.zoom_scroll_delta += 1.0;
                }
                while (this.zoom_scroll_delta >= 1.0) {
                    zoom_out();
                    this.zoom_scroll_delta -= 1.0;
                }
                return true;
            }
        } else {
            this.zoom_scroll_delta = 0;
        }
        return false;
    }

    private void on_preferred_height_changed(GLib.Variant? parameters) {
        double height = this.webkit_reported_height;
        if (parameters != null && parameters.classify() == DOUBLE) {
            // WebkitGtk (after 2.45.3) returns height without taking into account font scaling,
            // Multiply by `get_text_scale()` to fix the issue.
            // Related commit: https://github.com/WebKit/WebKit/commit/5713584438d253c13cb10966d7bac9cef1f9082f
            height = parameters.get_double() * get_text_scale();
        } else {
            warning("Could not get JS preferred height");
        }

        if (this.webkit_reported_height != height) {
            this.webkit_reported_height = height;
            notify_property("preferred-height");
        }
    }

    private void on_command_stack_changed(GLib.Variant? parameters) {
        if (parameters != null &&
            parameters.is_container() &&
            parameters.n_children() == 2) {
            GLib.Variant can_undo = parameters.get_child_value(0);
            GLib.Variant can_redo = parameters.get_child_value(1);
            command_stack_changed(
                can_undo.classify() == BOOLEAN && can_undo.get_boolean(),
                can_redo.classify() == BOOLEAN && can_redo.get_boolean()
            );
        } else {
            warning("Could not get JS command stack state");
        }
    }

    private void on_document_modified(GLib.Variant? parameters) {
        document_modified();
    }

    private void on_remote_resource_load_blocked(GLib.Variant? parameters) {
        remote_resource_load_blocked();
    }

    private void on_content_loaded(GLib.Variant? parameters) {
        this.is_content_loaded = true;
        update_unset_html_colors.begin();
        content_loaded();
    }

    private void on_selection_changed(GLib.Variant? parameters) {
        if (parameters != null && parameters.classify() == BOOLEAN) {
            this.has_selection = parameters.get_boolean();
        } else {
            warning("Could not get JS selection value");
        }
    }

    protected override void handle_page_message(string name,
                                                GLib.Variant? parameters) {
        if (name == MESSAGE_EXCEPTION) {
            var detail = new GLib.VariantDict(parameters);
            var error_name = detail.lookup_value("name", GLib.VariantType.STRING) as string;
            var log_message = detail.lookup_value("message", GLib.VariantType.STRING) as string;
            warning(
                "Error sending message from JS: %s: %s",
                error_name ?? "unknown",
                log_message ?? "unknown"
            );
        } else if (this.message_handlers.has_key(name)) {
            debug(
                "Message received: %s(%s)",
                name,
                parameters != null ? parameters.print(true) : ""
            );
            MessageCallable callback = this.message_handlers.get(name);
            callback.handler(parameters);
        } else {
            warning("Message with unknown handler received: %s", name);
        }
    }

}
