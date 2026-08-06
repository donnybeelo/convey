/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2017-2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public class ConversationWebView : Components.WebView {


    private const string DECEPTIVE_LINK_CLICKED = "deceptive_link_clicked";

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

    private static string? app_stylesheet = null;
    private static string? app_script = null;

    public static new void load_resources()
        throws Error {
        ConversationWebView.app_script = Components.WebView.load_app_script(
            "conversation-web-view.js"
        );
        ConversationWebView.app_stylesheet = Components.WebView.load_app_stylesheet(
            "conversation-web-view.css"
        );
    }


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
        add_user_script(ConversationWebView.app_script);
        add_user_stylesheet(ConversationWebView.app_stylesheet);
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
        // XXX Browser engines don't deal with the multiple
        // highlighting required by search folder matches, only single
        // highlighting for a find-like interface. For now, just
        // highlight the first term
        return yield find_text(Convey.Collection.first(terms), cancellable);
    }

    /**
     * Unmarks any search terms highlighted in the message view.
     */
    public void unmark_search_terms() {
        find_finish();
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
        } else {
            // Clamp height to something not too outrageous so we
            // don't get an XServer error trying to allocate a massive
            // window.
            const uint max_pixels = 8 * 1024 * 1024;
            int width = get_width();
            int height = this.preferred_height;
            if (height * width > max_pixels) {
                height = (int) Math.floor(max_pixels / (double) width);
            }

            minimum = natural = height;
        }

        minimum_baseline = natural_baseline = -1;
    }

    private void init() {
        register_message_callback(
            DECEPTIVE_LINK_CLICKED, on_deceptive_link_clicked
        );

        this.notify["preferred-height"].connect(() => queue_resize());

        // The view is allocated its full content height so it never
        // scrolls internally. Drop WebKit's own scroll controller so
        // scroll gestures bubble to the surrounding ScrolledWindow
        // whole and get stock GTK mechanics (kinetic deceleration,
        // etc). The base class's Ctrl+scroll zoom controller is
        // vertical-only, so leave that one in place.
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
