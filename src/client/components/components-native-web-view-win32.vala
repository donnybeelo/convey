/*
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Windows implementation of the platform's native web view.
 *
 * This is a placeholder: it presents the API that {@link
 * Components.WebView} and its subclasses expect, so that the client
 * builds and runs on Windows, but it does not yet embed a browser
 * engine. Message bodies and the composer therefore show nothing.
 *
 * Filling it in means hosting a WebView2 (Microsoft Edge) control:
 *
 *  * Embedding: GTK4 has no native child-widget support, so the control
 *    needs a borderless child HWND parented to this widget's toplevel
 *    HWND, with its geometry tracked from size_allocate and its
 *    visibility from map/unmap. The control composites above GTK's own
 *    rendering, so it cannot be clipped by a GtkScrolledWindow; the
 *    conversation viewer expects one view per message, which is why the
 *    port also collapses a thread into a single document.
 *  * Bridge: AddScriptToExecuteOnDocumentCreated for {@link
 *    add_user_script}, and PostWebMessageAsJson plus WebMessageReceived
 *    for {@link send_page_message} and {@link handle_page_message}.
 *    Everything the WebKitGTK web process extension does must move into
 *    the injected JavaScript, since WebView2 has no in-renderer hook.
 *  * Resources: a custom scheme handler for `cid:` and `convey:`, backed
 *    by {@link lookup_internal_resource}.
 *  * Remote content: WebResourceRequested, which is the direct
 *    counterpart of the extension's send_request filter and is what
 *    keeps remote images blocked until the user allows them.
 *
 * WebView2 is COM, so each of those needs a small C shim behind a VAPI.
 *
 * @see Components.NativeWebView (WebKitGTK implementation)
 */
public class Components.NativeWebView : Gtk.Widget {


    /** Initialises the browser engine for use by the client. */
    public static void init_platform(Application.Configuration config,
                                     GLib.File web_extension_dir) {
        // No engine yet, so nothing to initialise.
    }

    /** Returns a label naming the browser engine, for the about dialog. */
    public static string engine_version_label() {
        /// Application runtime information label
        return _("WebView2 version");
    }

    /** Returns the version of the browser engine in use. */
    public static string engine_version() {
        /// Application runtime information shown when no browser engine
        /// is available on this platform yet.
        return _("Not available");
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
     * this class grows an engine.
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


    protected NativeWebView(Application.Configuration config,
                            GLib.File? cache_dir = null) {
        Object();
        init_placeholder();
    }

    protected NativeWebView.with_related_view(Application.Configuration config,
                                              NativeWebView related) {
        Object();
        init_placeholder();
    }

    /** Adds a script to be run on each page loaded by this view. */
    public void add_user_script(string source) {
        // No engine yet.
    }

    /** Adds a stylesheet to be applied to each page loaded by this view. */
    public void add_user_stylesheet(string css, bool all_frames = false) {
        // No engine yet.
    }

    /** Sets the font used for the view's proportional text. */
    public void apply_document_font(Pango.FontDescription font) {
        // No engine yet.
    }

    /** Sets the font used for the view's monospaced text. */
    public void apply_monospace_font(Pango.FontDescription font) {
        // No engine yet.
    }

    /** Loads the given HTML into the view. */
    public void load_html(string? body, string? base_uri = null) {
        // No engine yet.
    }

    /** Stops any in-progress load. */
    public void stop_loading() {
        // No engine yet.
    }

    /** Determines if the view can display the given content type. */
    public bool can_show_mime_type(string mime_type) {
        return false;
    }

    /** Runs an editing command, such as Copy, on the view. */
    public void execute_editing_command(string command) {
        // No engine yet.
    }

    /** Runs an editing command with an argument on the view. */
    public void execute_editing_command_with_argument(string command,
                                                      string argument) {
        // No engine yet.
    }

    /** Evaluates JavaScript in the view's page. */
    public async void evaluate_javascript(string script,
                                          int length = -1,
                                          string? world_name = null,
                                          string? source_uri = null,
                                          GLib.Cancellable? cancellable = null)
        throws GLib.Error {
        // No engine yet.
    }

    /**
     * Calls a method on the page's JavaScript `convey` object.
     *
     * Always returns null, so callers expecting a value will raise a
     * {@link Util.JS.Error.TYPE}, which they already handle: the page
     * this would talk to does not exist yet.
     */
    public async Components.WebViewResponse? send_page_message(
        string name,
        GLib.Variant? parameters,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        return null;
    }

    /** Highlights the given text in the view, returning the match count. */
    public async uint find_text(string text, GLib.Cancellable cancellable)
        throws GLib.IOError.CANCELLED {
        return 0;
    }

    /** Removes any highlights added by {@link find_text}. */
    public void find_finish() {
        // No engine yet.
    }

    /** Shows the platform's print dialog for the view's content. */
    public void print_content(Gtk.Window? parent,
                              Gtk.PrintSettings settings) {
        // No engine yet.
    }

    /** Determines if the view has the data for a loaded resource. */
    public bool has_resource(string uri) {
        return false;
    }

    /** Returns the data of a resource the view loaded, if it has it. */
    public async GLib.Bytes? get_resource_data(string uri,
                                               GLib.Cancellable? cancellable)
        throws GLib.Error {
        return null;
    }

    /** Forgets the data of every resource loaded so far. */
    public void clear_resources() {
        // No engine yet.
    }

    /** Returns the text styles applied at the editing caret. */
    public Components.WebViewTypingAttributes get_typing_attributes() {
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

    private void init_placeholder() {
        add_css_class("convey-web-view-placeholder");
        set_layout_manager(new Gtk.BinLayout());
        var label = new Gtk.Label(
            /// Placeholder shown in place of a message body on platforms
            /// with no browser engine available yet.
            _("Message display is not available on this platform yet")
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
