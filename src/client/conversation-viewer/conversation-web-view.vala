/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2017-2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public class ConversationWebView : Components.WebView {


    private const string DECEPTIVE_LINK_CLICKED = "deceptive_link_clicked";
    private const double MAGIC_SCROLL_FACTOR = 2.5;

    /** Specifies the type of deceptive link text when clicked. */
    public enum DeceptiveText {
        // Keep this in sync with JS ConversationPageState
        /** No deceptive text found. */
        NOT_DECEPTIVE = 0,
        /** The link had an invalid HREF value. */
        DECEPTIVE_HREF = 1,
        /** The domain of the link's text did not match the HREF. */
        DECEPTIVE_DOMAIN = 2;
    }

    private static WebKit.UserStyleSheet? app_stylesheet = null;
    private static WebKit.UserScript? app_script = null;

    public static new void load_resources()
        throws Error {
        ConversationWebView.app_script = Components.WebView.load_app_script(
            "conversation-web-view.js"
        );
        ConversationWebView.app_stylesheet = Components.WebView.load_app_stylesheet(
            "conversation-web-view.css"
        );
    }


    public bool is_truncated { get; private set; default = false; }

    private bool scrolls_internally = false;
    private double max_page_height = 0;

    /** Emitted when the user clicks on a link with deceptive text. */
    public signal void deceptive_link_clicked(
        DeceptiveText reason, string text, string href, Gdk.Rectangle location
    );


    /**
     * Constructs a new web view for displaying an email message body.
     *
     * A new WebKitGTK WebProcess will be constructed for this view.
     */
    public ConversationWebView(Application.Configuration config, GLib.File? cache_dir) {
        base(config, cache_dir);
        init();

        // These only need to be added when creating a new WebProcess,
        // not when sharing one
        this.user_content_manager.add_script(ConversationWebView.app_script);
        this.user_content_manager.add_style_sheet(ConversationWebView.app_stylesheet);
    }

    /**
     * Constructs a new web view for displaying an email message body.
     *
     * The WebKitGTK WebProcess will be shared with the related view's
     * process.
     */
    internal ConversationWebView.with_related_view(
        Application.Configuration config,
        GLib.File? cache_dir,
        ConversationWebView related
    ) {
        base.with_related_view(config, related);
        init();
    }

    /**
     * Constructs a web view that scrolls its own content.
     *
     * The WebKitGTK WebProcess will be shared with the related view's
     * process.
     */
    internal ConversationWebView.standalone(
        Application.Configuration config,
        ConversationWebView related
    ) {
        base.with_related_view(config, related);
        this.scrolls_internally = true;
        init();
    }

    /**
     * Returns the current selection, for prefill as find text.
     */
    public async string? get_selection_for_find() throws Error{
        return yield call_returning<string?>(
            Util.JS.callable("getSelectionForFind"), null
        );
    }

    /**
     * Returns the current selection, for quoting in a message.
     */
    public async string? get_selection_for_quoting() throws Error {
        return yield call_returning<string?>(
            Util.JS.callable("getSelectionForQuoting"), null
        );
    }

    /**
     * Returns the y value for a element, by its id
     */
    public async int? get_anchor_target_y(string anchor_body)
        throws GLib.Error {
        return yield call_returning<int?>(
            Util.JS.callable("getAnchorTargetY").string(anchor_body), null
        );
    }

    /**
     * Highlights user search terms in the message view.
     *
     * Returns the number of matching search terms.
     */
    public async uint highlight_search_terms(Gee.Collection<string> terms,
                                             GLib.Cancellable cancellable)
        throws GLib.IOError.CANCELLED {
        WebKit.FindController controller = get_find_controller();

        // Remove existing highlights
        controller.search_finish();

        // Browser engines don't deal with the multiple
        // highlighting required by search folder matches, only
        // single highlighting for a find-like interface. For now,
        // just highlight the first term

        uint found = 0;
        bool finished = false;

        SourceFunc callback = this.highlight_search_terms.callback;
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
            Convey.Collection.first(terms),
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
            throw new IOError.CANCELLED(
                "ConversationWebView highlight search terms cancelled"
            );
        }

        return found;
    }

    /**
     * Unmarks any search terms highlighted in the message view.
     */
    public void unmark_search_terms() {
        get_find_controller().search_finish();
    }

    public override void measure(Gtk.Orientation orientation,
                                 int for_size,
                                 out int minimum,
                                 out int natural,
                                 out int minimum_baseline,
                                 out int natural_baseline) {
        if (orientation == Gtk.Orientation.HORIZONTAL) {
            // We always want the view to be sized according to the available
            // space in the parent, not by the width of the web view.
            minimum = natural = 0;
        } else if (this.scrolls_internally) {
            minimum = natural = 0;
        } else {
            int height = int.min(this.preferred_height, max_height());
            minimum = natural = height;
        }

        minimum_baseline = natural_baseline = -1;
    }

    private int max_height() {
        const uint max_pixels = 8 * 1024 * 1024;
        const int max_texture_size = 16384;
        int height = max_texture_size / get_scale_factor();
        int width = get_width();
        if (width > 0) {
            height = int.min(height, (int) (max_pixels / width));
        }
        return height;
    }

    private void init() {
        register_message_callback(
            DECEPTIVE_LINK_CLICKED, on_deceptive_link_clicked
        );
        if (!this.scrolls_internally) {
            this.content_loaded.connect(
                () => call_js(Util.JS.callable("disableScrolling"))
            );
        }

        this.notify["preferred-height"].connect(() => {
            this.is_truncated = this.preferred_height > max_height();
            queue_resize();
            double max_page_height =
                max_height() * 0.98 / (this.zoom_level * get_text_scale());
            if (!this.scrolls_internally &&
                max_page_height != this.max_page_height) {
                this.max_page_height = max_page_height;
                call_js(
                    Util.JS.callable("fitToHeight").double(max_page_height)
                );
            }
        });

        // Unless standalone, the view is allocated its full content
        // height so it never scrolls internally. Drop WebKit's own scroll
        // controller so scroll gestures bubble to the surrounding
        // ScrolledWindow whole and get stock GTK mechanics (kinetic
        // deceleration, etc). The base class's Ctrl+scroll zoom
        // controller is vertical-only, so leave that one in place.
        var to_remove = new Gee.ArrayList<Gtk.EventController>();
        var controllers = observe_controllers();
        for (uint i = 0; i < controllers.get_n_items(); i++) {
            var scroll = controllers.get_item(i) as Gtk.EventControllerScroll;
            if (scroll != null &&
                scroll.flags != Gtk.EventControllerScrollFlags.VERTICAL) {
                to_remove.add(scroll);
            }
        }
        foreach (var scroll in to_remove) {
            remove_controller(scroll);
        }

        var kinetic = new Gtk.EventControllerScroll(
            Gtk.EventControllerScrollFlags.BOTH_AXES |
            Gtk.EventControllerScrollFlags.KINETIC
        );
        unowned var controller = kinetic;
        string fling = "flingHorizontally";
        if (this.scrolls_internally) {
            fling = "flingPage";
            kinetic.scroll.connect(on_page_scroll);
        } else {
            kinetic.scroll.connect(on_horizontal_scroll);
        }
        kinetic.decelerate.connect((vx, vy) => {
                if (controller.get_unit() == Gdk.ScrollUnit.SURFACE) {
                    vx *= MAGIC_SCROLL_FACTOR;
                    vy *= MAGIC_SCROLL_FACTOR;
                }
                call_js(Util.JS.callable(fling).double(vx).double(vy));
            });
        kinetic.scroll_begin.connect(() => call_js(Util.JS.callable(fling).double(0).double(0)));
        add_controller(kinetic);
    }

    private bool on_page_scroll(Gtk.EventControllerScroll controller,
                                double dx, double dy) {
        if (controller.get_unit() == Gdk.ScrollUnit.WHEEL) {
            dx *= Math.pow(get_width(), 2.0 / 3.0);
            dy *= Math.pow(get_height(), 2.0 / 3.0);
        } else {
            dx *= MAGIC_SCROLL_FACTOR;
            dy *= MAGIC_SCROLL_FACTOR;
        }
        call_js(Util.JS.callable("scrollPage").double(dx).double(dy));
        return true;
    }

    private bool on_horizontal_scroll(Gtk.EventControllerScroll controller,
                                      double dx, double dy) {
        bool wheel = controller.get_unit() == Gdk.ScrollUnit.WHEEL;
        bool shift = wheel && (controller.get_current_event_state() & Gdk.ModifierType.SHIFT_MASK) != 0;
        double d = shift ? dy : dx;
        if (d != 0) {
            call_js(Util.JS.callable("scrollHorizontally").double(wheel ? d * 50 : d * MAGIC_SCROLL_FACTOR));
        }
        return shift;
    }

    private void call_js(Util.JS.Callable target) {
        call_void.begin(target, null, (obj, res) => {
            try {
                call_void.end(res);
            } catch (GLib.Error err) {
                debug("Horizontal scroll failed: %s", err.message);
            }
        });
    }

    private void on_deceptive_link_clicked(GLib.Variant? parameters) {
        var dict = new GLib.VariantDict(parameters);
        uint reason = (uint) dict.lookup_value(
            "reason", GLib.VariantType.DOUBLE
        ).get_double();

        string href = dict.lookup_value(
            "href", GLib.VariantType.STRING
        ).get_string();

        string text = dict.lookup_value(
            "text", GLib.VariantType.STRING
        ).get_string();

        Gdk.Rectangle location = Gdk.Rectangle();
        var location_dict = new GLib.VariantDict(
            dict.lookup_value("location", GLib.VariantType.VARDICT)
        );
        location.x = (int) location_dict.lookup_value(
            "x", GLib.VariantType.DOUBLE
        ).get_double();
        location.y = (int) location_dict.lookup_value(
            "y", GLib.VariantType.DOUBLE
        ).get_double();
        location.width = (int) location_dict.lookup_value(
            "width", GLib.VariantType.DOUBLE
        ).get_double();
        location.height = (int) location_dict.lookup_value(
            "height", GLib.VariantType.DOUBLE
        ).get_double();

        deceptive_link_clicked(
            (DeceptiveText) reason, text, href, location
        );
    }

}
