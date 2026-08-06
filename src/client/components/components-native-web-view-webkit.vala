/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2016-2020 Michael Gratton <mike@vee.net>
 * Copyright © 2026 Convey contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * WebKitGTK implementation of the platform's native web view.
 *
 * {@link Components.WebView} derives from this class rather than from
 * a specific browser engine, so that each platform can supply its own
 * implementation with the same API. Meson selects exactly one
 * implementation at build time based on the host system:
 *
 *  * Linux and BSD: this file, wrapping WebKitGTK.
 *  * Windows: components-native-web-view-win32.vala, wrapping WebView2.
 *  * macOS: components-native-web-view-darwin.vala, wrapping WKWebView.
 *
 * There is deliberately no interface pinning the contract: the members
 * used by {@link Components.WebView} and its subclasses are the
 * contract, and a platform implementation that is missing one simply
 * fails to compile on that platform.
 */
public class Components.NativeWebView : WebKit.WebView {


    private static WebKit.WebContext? default_context = null;


    /**
     * Initialises the browser engine for use by the client.
     *
     * Must be called once, before any view is constructed.
     */
    public static void init_platform(Application.Configuration config,
                                     GLib.File web_extension_dir) {
        WebKit.WebContext context = new WebKit.WebContext();

        // Configure WebProcess sandboxing
        context.add_path_to_sandbox(web_extension_dir.get_path(), true);

        // Use the doc browser model so that we get some caching of
        // resources between email body loads.
        context.set_cache_model(WebKit.CacheModel.DOCUMENT_BROWSER);

        context.register_uri_scheme("cid", (req) => {
                NativeWebView? view = req.get_web_view() as NativeWebView;
                if (view != null) {
                    view.serve_request(req, false);
                }
            });
        context.register_uri_scheme("convey", (req) => {
                NativeWebView? view = req.get_web_view() as NativeWebView;
                if (view != null) {
                    view.serve_request(req, true);
                }
            });
        context.initialize_web_process_extensions.connect((context) => {
                context.set_web_process_extensions_directory(
                    web_extension_dir.get_path()
                );
                context.set_web_process_extensions_initialization_user_data(
                    new Variant.boolean(config.enable_debug)
                );
            });

        update_spellcheck(context, config);
        config.settings.changed[
            Application.Configuration.SPELL_CHECK_LANGUAGES
        ].connect(() => {
                update_spellcheck(context, config);
            });

        NativeWebView.default_context = context;
    }

    /**
     * Returns a label naming the browser engine, for the about dialog.
     */
    public static string engine_version_label() {
        /// Application runtime information label
        return _("WebKitGTK version");
    }

    /** Returns the version of the browser engine in use. */
    public static string engine_version() {
        return "%u.%u.%u".printf(
            WebKit.get_major_version(),
            WebKit.get_minor_version(),
            WebKit.get_micro_version()
        );
    }

    private static inline void update_spellcheck(WebKit.WebContext context,
                                                 Application.Configuration config) {
        string[] langs = config.get_spell_check_languages();
        context.set_spell_checking_enabled(langs.length > 0);
        context.set_spell_checking_languages(langs);
    }

    private static inline uint to_engine_font_size(Pango.FontDescription font) {
        // XXX GTK4 I have no idea what to do here
        double size = font.get_size();
        if (!font.get_size_is_absolute()) {
            size = size / Pango.SCALE;
        }
        return (uint) WebKit.Settings.font_size_to_pixels((uint) size);
    }


    /** Emitted when the user clicks a link in the view. */
    public signal void link_clicked(string uri);

    /** Emitted when an internal resource has been served to the view. */
    public signal void internal_resource_served(string name);


    protected NativeWebView(Application.Configuration config,
                            GLib.File? cache_dir = null) {
        WebKit.Settings setts = new WebKit.Settings();
        setts.allow_modal_dialogs = false;
        setts.default_charset = "UTF-8";
        setts.enable_developer_extras = config.enable_inspector;
        setts.enable_fullscreen = false;
        setts.enable_html5_database = false;
        setts.enable_html5_local_storage = false;
        setts.enable_javascript = true;
        setts.enable_javascript_markup = false;
        setts.enable_media_stream = false;
        setts.enable_offline_web_application_cache = false;
        setts.enable_page_cache = false;
        // Let WebKit use the GPU. Software rendering scrolls poorly,
        // especially under fractional scaling where each message's
        // surface is rescaled on the CPU every frame. If many-message
        // threads exhaust VRAM on low-end GPUs, gate this behind a
        // setting instead of forcing NEVER.
        setts.hardware_acceleration_policy =
            WebKit.HardwareAccelerationPolicy.ALWAYS;
        setts.javascript_can_access_clipboard = true;

        // Use cache dir for both cache & data since a) emails shouldn't be
        // storing data anyway, and b) so WK doesn't use the default, shared datadir
        WebKit.NetworkSession nw_session;
        if (cache_dir != null) {
            nw_session = new WebKit.NetworkSession(
                cache_dir.get_path(),
                cache_dir.get_path()
            );
        } else {
            nw_session = new WebKit.NetworkSession.ephemeral();
        }

        Object(
            settings: setts,
            user_content_manager: new WebKit.UserContentManager(),
            web_context: NativeWebView.default_context,
            network_session: nw_session
        );
        init_native();
    }

    /**
     * Constructs a view sharing the given view's engine process.
     *
     * The new view will use the same settings and injected content as
     * the related view's.
     */
    protected NativeWebView.with_related_view(Application.Configuration config,
                                              NativeWebView related) {
        Object(
            related_view: related,
            settings: related.get_settings(),
            user_content_manager: related.user_content_manager
        );
        init_native();
    }

    /** Adds a script to be run on each page loaded by this view. */
    public void add_user_script(string source) {
        this.user_content_manager.add_script(
            new WebKit.UserScript(
                source,
                WebKit.UserContentInjectedFrames.TOP_FRAME,
                WebKit.UserScriptInjectionTime.START,
                null,
                null
            )
        );
    }

    /** Adds a stylesheet to be applied to each page loaded by this view. */
    public void add_user_stylesheet(string css, bool all_frames = false) {
        this.user_content_manager.add_style_sheet(
            new WebKit.UserStyleSheet(
                css,
                all_frames
                    ? WebKit.UserContentInjectedFrames.ALL_FRAMES
                    : WebKit.UserContentInjectedFrames.TOP_FRAME,
                WebKit.UserStyleLevel.USER,
                null,
                null
            )
        );
    }

    /** Sets the font used for the view's proportional text. */
    public void apply_document_font(Pango.FontDescription font) {
        WebKit.Settings settings = get_settings();
        settings.default_font_family = font.get_family();
        settings.default_font_size = to_engine_font_size(font);
        set_settings(settings);
    }

    /** Sets the font used for the view's monospaced text. */
    public void apply_monospace_font(Pango.FontDescription font) {
        WebKit.Settings settings = get_settings();
        settings.monospace_font_family = font.get_family();
        settings.default_monospace_font_size = to_engine_font_size(font);
        set_settings(settings);
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
        WebKit.UserMessage? response = yield send_message_to_page(
            new WebKit.UserMessage(name, parameters), cancellable
        );
        return (
            response != null
            ? new Components.WebViewResponse(response.name, response.parameters)
            : null
        );
    }

    /**
     * Highlights the given text in the view.
     *
     * Returns the number of matches found.
     */
    public async uint find_text(string text, GLib.Cancellable cancellable)
        throws GLib.IOError.CANCELLED {
        WebKit.FindController controller = get_find_controller();

        // Remove existing highlights
        controller.search_finish();

        uint found = 0;
        bool finished = false;

        SourceFunc callback = this.find_text.callback;
        ulong found_handler = controller.found_text.connect((count) => {
                if (!finished) {
                    found = count;
                    callback();
                }
            });
        ulong not_found_handler = controller.failed_to_find_text.connect(() => {
                if (!finished) {
                    callback();
                }
            });
        ulong cancelled_handler = cancellable.cancelled.connect(() => {
                if (!finished) {
                    // Do this at idle since per the docs for
                    // GLib.Cancellable.disconnect, disconnecting a
                    // handler from within a handler causes a deadlock.
                    GLib.Idle.add(() => callback());
                }
            });

        controller.search(
            text,
            WebKit.FindOptions.CASE_INSENSITIVE |
            WebKit.FindOptions.WRAP_AROUND,
            128
        );

        yield;

        finished = true;
        controller.disconnect(found_handler);
        controller.disconnect(not_found_handler);
        cancellable.disconnect(cancelled_handler);

        if (cancellable.is_cancelled()) {
            throw new IOError.CANCELLED("Web view find text cancelled");
        }

        return found;
    }

    /** Removes any highlights added by {@link find_text}. */
    public void find_finish() {
        get_find_controller().search_finish();
    }

    /** Shows the platform's print dialog for the view's content. */
    public void print_content(Gtk.Window? parent,
                              Gtk.PrintSettings settings) {
        var op = new WebKit.PrintOperation(this);
        op.set_print_settings(settings);
        op.run_dialog(parent);
    }

    /** Determines if the view has the data for a loaded resource. */
    public bool has_resource(string uri) {
        return this.resources.has_key(uri);
    }

    /**
     * Returns the data of a resource the view loaded, if it has it.
     *
     * Used to save an image the user asked for without fetching it a
     * second time.
     */
    public async GLib.Bytes? get_resource_data(string uri,
                                               GLib.Cancellable? cancellable)
        throws GLib.Error {
        WebKit.WebResource? resource = this.resources[uri];
        if (resource == null) {
            return null;
        }
        uint8[] data = yield resource.get_data(cancellable);
        return new GLib.Bytes(data);
    }

    /** Returns the text styles applied at the editing caret. */
    public Components.WebViewTypingAttributes get_typing_attributes() {
        uint mask = get_editor_state().get_typing_attributes();
        Components.WebViewTypingAttributes attrs = 0;
        if ((mask & WebKit.EditorTypingAttributes.BOLD) != 0) {
            attrs |= BOLD;
        }
        if ((mask & WebKit.EditorTypingAttributes.ITALIC) != 0) {
            attrs |= ITALIC;
        }
        if ((mask & WebKit.EditorTypingAttributes.UNDERLINE) != 0) {
            attrs |= UNDERLINE;
        }
        if ((mask & WebKit.EditorTypingAttributes.STRIKETHROUGH) != 0) {
            attrs |= STRIKETHROUGH;
        }
        return attrs;
    }

    /** Emitted when the text styles at the editing caret change. */
    public signal void typing_attributes_changed();

    /**
     * Emitted when the user asks for a context menu in the view.
     *
     * The coordinates are relative to this widget. The engine's own menu
     * is shown only if no handler returns true, so a handler that presents
     * a menu of its own should do so.
     */
    public signal bool context_menu_requested(
        Components.WebViewHitTest hit_test, double x, double y
    );

    /** Emitted when the content under the pointer changes. */
    public signal void pointer_target_changed(
        Components.WebViewHitTest hit_test
    );

    /**
     * Emitted when the view starts loading a resource.
     *
     * Named apart from WebKit's own resource-load-started, which this is
     * driven by.
     */
    public signal void resource_started(string uri);

    /** Emitted when a resource the view was loading has finished. */
    public signal void resource_finished(string uri);

    /**
     * Returns the content of an internal resource, if known.
     *
     * Called when the page requests a `convey:` or `cid:` URI.
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

    private Gee.Map<string,WebKit.WebResource> resources =
        new Gee.HashMap<string,WebKit.WebResource>();

    // Where the pointer last was, in this widget's coordinates. Tracked
    // rather than taken from the menu's triggering event: that event is
    // not always present, and when it is its coordinates are relative to
    // the surface rather than to this widget.
    private double pointer_x = 0;
    private double pointer_y = 0;


    private void init_native() {
        var motion = new Gtk.EventControllerMotion();
        // Capture phase: the web view handles pointer events itself, so a
        // controller in the default bubble phase would not see them.
        motion.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        motion.enter.connect((x, y) => set_pointer_position(x, y));
        motion.motion.connect((x, y) => set_pointer_position(x, y));
        add_controller(motion);

        this.context_menu.connect(on_context_menu);
        this.mouse_target_changed.connect(on_mouse_target_changed);
        this.resource_load_started.connect(on_resource_load_started);
        this.decide_policy.connect(on_decide_policy);
        this.web_process_terminated.connect((reason) => {
                warning("Web process crashed: %s", reason.to_string());
            });
        this.user_message_received.connect((message) => {
                handle_page_message(message.name, message.parameters);
                return true;
            });
        get_editor_state().notify["typing-attributes"].connect(
            () => typing_attributes_changed()
        );
    }

    private static Components.WebViewHitTest to_hit_test(
        WebKit.HitTestResult hit
    ) {
        return new Components.WebViewHitTest(
            hit.context_is_link() ? hit.get_link_uri() : null,
            hit.context_is_link() ? hit.get_link_label() : null,
            hit.context_is_image() ? hit.get_image_uri() : null,
            hit.context_is_media() ? hit.get_media_uri() : null,
            hit.context_is_editable(),
            hit.context_is_selection()
        );
    }

    private inline void set_pointer_position(double x, double y) {
        this.pointer_x = x;
        this.pointer_y = y;
    }

    private bool on_context_menu(WebKit.WebView view,
                                 WebKit.ContextMenu menu,
                                 WebKit.HitTestResult hit) {
        return context_menu_requested(
            to_hit_test(hit), this.pointer_x, this.pointer_y
        );
    }

    private void on_mouse_target_changed(WebKit.WebView view,
                                         WebKit.HitTestResult hit,
                                         uint modifiers) {
        pointer_target_changed(to_hit_test(hit));
    }

    private void on_resource_load_started(WebKit.WebView view,
                                          WebKit.WebResource resource,
                                          WebKit.URIRequest request) {
        string uri = resource.get_uri();
        this.resources[uri] = resource;
        resource_started(uri);
        resource.finished.connect(() => resource_finished(uri));
    }

    /** Forgets the data of every resource loaded so far. */
    public void clear_resources() {
        this.resources.clear();
    }

    private void serve_request(WebKit.URISchemeRequest request,
                               bool internal_scheme) {
        string uri = request.get_uri();
        string path = GLib.Uri.unescape_string(request.get_path());
        Convey.Memory.Buffer? buf = lookup_internal_resource(uri, path);
        if (buf != null) {
            request.finish(buf.get_input_stream(), buf.size, null);
            if (uri != Components.WebView.INTERNAL_URL_BODY) {
                internal_resource_served(path);
            }
        } else {
            request.finish_error(
                new FileError.NOENT(
                    internal_scheme ? "Unknown internal URL" : "Unknown CID"
                )
            );
        }
    }

    // This method is called only when determining if something should
    // be loaded for display in the web view as the primary
    // resource. It is not used to determine if sub-resources such as
    // images or JS will be loaded. So we only allow convey:body loads,
    // and notify but ignore if the user attempts to click on a link,
    // and deny everything else.
    private bool on_decide_policy(WebKit.WebView view,
                                  WebKit.PolicyDecision policy,
                                  WebKit.PolicyDecisionType type) {
        if (type == WebKit.PolicyDecisionType.NAVIGATION_ACTION ||
            type == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) {
            WebKit.NavigationPolicyDecision nav_policy =
                (WebKit.NavigationPolicyDecision) policy;
            WebKit.NavigationAction nav_action =
                nav_policy.get_navigation_action();
            switch (nav_action.get_navigation_type()) {
            case WebKit.NavigationType.OTHER:
                if (nav_action.get_request().uri ==
                    Components.WebView.INTERNAL_URL_BODY) {
                    policy.use();
                } else {
                    policy.ignore();
                }
                break;

            case WebKit.NavigationType.LINK_CLICKED:
                // Let the app know a user activated a link, but don't
                // try to load it ourselves.

                // We need to call ignore() before emitting the signal
                // to unblock the WebKit WebProcess, otherwise the
                // call chain for mailto links will cause the
                // WebProcess to deadlock, and the resulting composer
                // will be useless. See Convey Bug 771504
                // <https://bugzilla.gnome.org/show_bug.cgi?id=771504>
                // and WebKitGTK Bug 182528
                // <https://bugs.webkit.org/show_bug.cgi?id=182528>
                policy.ignore();
                link_clicked(nav_action.get_request().uri);
                break;

            default:
                policy.ignore();
                break;
            }
        } else {
            policy.ignore();
        }
        return Gdk.EVENT_STOP;
    }

}
