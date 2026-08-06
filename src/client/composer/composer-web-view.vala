/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2016 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * A WebView for editing messages in the composer.
 */
public class Composer.WebView : Components.WebView {

    /** HTML id used for the main text section of the message body. */
    public const string BODY_HTML_ID = "convey-body";
    /** HTML id used for the signature section of the message body. */
    public const string SIGNATURE_HTML_ID = "convey-signature";
    /** HTML id used for the bottom-quote section of the message body. */
    public const string QUOTE_HTML_ID = "convey-quote";

    // Markup fragments used when loading a new message.
    private const string HTML_PRE = """<html><body class="%s">""";
    private const string HTML_POST = """</body></html>""";
    private const string BODY_PRE = """
<div id="%s" dir="auto">""";
    private const string BODY_POST = """</div>
<div id="%s" class="convey-no-display" dir="auto"></div>
""";
    private const string QUOTE = """
<div id="%s" dir="auto"><br />%s</div>
""";
    private const string CURSOR = "<div><span id=\"cursormarker\"></span><br /></div>";
    private const string SPACER = "<div><br /></div>";

    // WebKit message handler names
    private const string CURSOR_CONTEXT_CHANGED = "cursor_context_changed";
    private const string DRAG_DROP_RECEIVED = "drag_drop_received";
    private const string SCROLLED = "scrolled";

    /** Whether the body is scrolled to its top edge. */
    public bool body_at_top { get; private set; default = true; }

    /** Whether the body is scrolled to its bottom edge. */
    public bool body_at_bottom { get; private set; default = true; }

    /**
     * Encapsulates editing-related state for a specific DOM node.
     *
     * This must be kept in sync with the JS object of the same name.
     */
    public class EditContext : Object {

        private const uint LINK_MASK = 1 << 0;

        private const string[] SANS_FAMILY_NAMES = {
            "sans", "arial", "trebuchet", "helvetica"
        };
        private const string[] SERIF_FAMILY_NAMES = {
            "serif", "georgia", "times"
        };
        private const string[] MONO_FAMILY_NAMES = {
            "monospace", "courier", "console"
        };

        private static Gee.HashMap<string,string> font_family_map =
            new Gee.HashMap<string,string>();

        static construct {
            foreach (string name in SANS_FAMILY_NAMES) {
                font_family_map[name] = "sans";
            }
            foreach (string name in SERIF_FAMILY_NAMES) {
                font_family_map[name] = "serif";
            }
            foreach (string name in MONO_FAMILY_NAMES) {
                font_family_map[name] = "monospace";
            }
        }


        public bool is_link { get { return (this.context & LINK_MASK) > 0; } }
        public string link_url { get; private set; default = ""; }
        public string font_family { get; private set; default = "sans"; }
        public uint font_size { get; private set; default = 12; }
        public Gdk.RGBA font_color {
            get;
            private set;
            default = { 0, 0, 0, 1 };
        }

        private uint context = 0;

        public EditContext(string message) {
            string[] values = message.split(";");
            this.context = (uint) uint64.parse(values[0]);

            this.link_url = values[1];

            string view_name = values[2].down();
            foreach (string specific_name in EditContext.font_family_map.keys) {
                if (specific_name in view_name) {
                    this.font_family = EditContext.font_family_map[specific_name];
                    break;
                }
            }

            this.font_size = (uint) uint64.parse(values[3]);

            Gdk.RGBA font_color = {0, 0, 0, 0};
            font_color.parse(values[4]);
            this.font_color = font_color;
        }

    }


    private static string? app_style = null;
    private static string? app_script = null;

    public static new void load_resources()
        throws Error {
        WebView.app_style = Components.WebView.load_app_stylesheet(
            "composer-web-view.css"
        );
        WebView.app_script = Components.WebView.load_app_script(
            "composer-web-view.js"
        );
    }

    /**
     * Determines if the body contains any non-boilerplate content.
     *
     * Currently, only a signatures are considered to be boilerplate.
     * Any user-made changes or message body content from a
     * forwarded/replied-to message present will make the view
     * considered to be non-empty.
     */
    public bool is_empty { get; private set; default = true; }

    /** Determines if the view is in rich text mode. */
    public bool is_rich_text { get; private set; default = true; }


    /** Emitted when the cursor's edit context has changed. */
    public signal void cursor_context_changed(EditContext cursor_context);

    /** Emitted when an image file has been dropped on the composer */
    public signal void image_file_dropped(string filename, string type, uint8[] contents);

    /**
     * Emitted when a file URI has been dropped on the composer body.
     *
     * Files dragged from a file manager arrive as URIs rather than as
     * in-page File objects, so the content must be read natively.
     */
    public signal void image_uri_dropped(string uri);


    public WebView(Application.Configuration config, GLib.File cache_dir) {
        base(config, cache_dir);

        add_user_stylesheet(WebView.app_style);
        add_user_script(WebView.app_script);

        register_message_callback(CURSOR_CONTEXT_CHANGED, on_cursor_context_changed);
        register_message_callback(DRAG_DROP_RECEIVED, on_drag_drop_received);
        register_message_callback(SCROLLED, on_scrolled);

        // Approximate is_empty via undo availability: if there is
        // nothing to undo, the body hasn't been edited
        this.command_stack_changed.connect((can_undo, can_redo) => {
                this.is_empty = !can_undo;
            });
    }

    /**
     * Loads a message HTML body into the view.
     */
    public new void load_html(string body,
                              string quote,
                              bool top_posting,
                              bool body_complete) {
        base.load_html(
            get_internal_html(body, quote, top_posting, body_complete)
        );
    }

    /**
     * Loads a message HTML body into the view.
     */
    public new void load_html_headless(string body,
                                       string quote,
                                       bool top_posting,
                                       bool body_complete) {
        base.load_html_headless(
            get_internal_html(body, quote, top_posting, body_complete)
        );
    }

    /**
     * Returns the view's content as HTML without being cleaned.
     */
    public async string? get_html_for_draft() throws Error {
        return yield call_returning<string?>(
            Util.JS.callable("getHtml").bool(false), null
        );
    }

    /**
     * Sets whether the editor is in rich text or plain text mode.
     */
    public void set_rich_text(bool enabled) {
        this.is_rich_text = enabled;
        if (this.is_content_loaded) {
            this.call_void.begin(
                Util.JS.callable("setRichText").bool(enabled), null
            );
        }
    }

    /**
     * Moves the editing caret to the given viewport coordinates.
     *
     * Used to insert dropped content where the user dropped it.
     */
    public void set_cursor_at_point(double x, double y) {
        this.call_void.begin(
            Util.JS.callable("setCursorAtPoint").double(x).double(y), null
        );
    }

    /**
     * Undoes the last edit operation.
     */
    public void undo() {
        this.call_void.begin(Util.JS.callable("undo"), null);
    }

    /**
     * Redoes the last undone edit operation.
     */
    public void redo() {
        this.call_void.begin(Util.JS.callable("redo"), null);
    }

    /**
     * Saves the current text selection so it can be restored later.
     *
     * Returns an id to be used to refer to the selection in
     * subsequent calls.
     */
    public async string? save_selection() throws Error {
        return yield call_returning<string?>(
            Util.JS.callable("saveSelection"), null
        );
    }

    /**
     * Removes a saved selection.
     */
    public void free_selection(string id) {
        this.call_void.begin(Util.JS.callable("freeSelection").string(id), null);
    }

    /**
     * Cuts selected content and sends it to the clipboard.
     */
    public void cut_clipboard() {
        execute_editing_command(WebKit.EDITING_COMMAND_CUT);
    }

    /**
     * Pastes plain text from the clipboard into the view.
     */
    public void paste_plain_text() {
        var clipboard = get_clipboard();
        clipboard.read_text_async.begin(null, (obj, res) => {
            try {
                string text = clipboard.read_text_async.end(res);
                if (text != null)
                    insert_text(text);
            } catch (Error err) {
                debug("Couldn't read text from clipboard to paste: %s", err.message);
            }
        });
    }

    /**
     * Pastes rich text from the clipboard into the view.
     */
    public void paste_rich_text() {
        execute_editing_command(WebKit.EDITING_COMMAND_PASTE);
    }

    /**
     * Inserts some text at the current text cursor location.
     */
    public void insert_text(string text) {
        execute_editing_command_with_argument("inserttext", text);

        // Note the inserttext command will not scroll if needed.
        // WebKit only allows scrolling a node into view, not an
        // arbitrary position within a text node, so fixing that
        // would need a placeholder node inserted at the cursor via
        // the page JS.
    }

    /**
     * Inserts some HTML at the current text cursor location.
     */
    public void insert_html(string markup) {
        execute_editing_command_with_argument("insertHTML", markup);
    }

    /**
     * Inserts or updates an A element at the current text cursor location.
     *
     * If the cursor is located on an A element, the element's HREF
     * will be updated, else if some text is selected, an A element
     * will be inserted wrapping the selection.
     */
    public void insert_link(string href, string selection_id) {
        this.call_void.begin(
            Util.JS.callable(
                "insertLink"
            ).string(href).string(selection_id),
            null
        );
    }

    /**
     * Removes the A element at the current text cursor location.
     *
     * If only part of the A element is selected, only that part is
     * unlinked, possibly creating two new A elements flanking the
     * unlinked section.
     */
    public void delete_link(string selection_id) {
        this.call_void.begin(
            Util.JS.callable("deleteLink").string(selection_id),
            null
        );
    }

    /**
     * Inserts an IMG element at the current text cursor location.
     */
    public void insert_image(string src) {
        // Use insertHTML instead of insertImage here so
        // we can specify a max width inline, preventing
        // large images from overflowing the view port.
        execute_editing_command_with_argument(
            "insertHTML",
            @"<img style=\"max-width: 100%\" src=\"$src\">"
        );
    }

    /**
     * Indents the line at the current text cursor location.
     */
    public void indent_line() {
        this.call_void.begin(Util.JS.callable("indentLine"), null);
    }

    public void insert_olist() {
        this.call_void.begin(Util.JS.callable("insertOrderedList"), null);
    }

    public void insert_ulist() {
        this.call_void.begin(Util.JS.callable("insertUnorderedList"), null);
    }

    /**
     * Updates the signature block if it has not been deleted.
     */
    public new void update_signature(string signature) {
        this.call_void.begin(
            Util.JS.callable("updateSignature").string(signature), null
        );
    }

    /**
     * Removes the quoted message (if any) from the composer.
     */
    public void delete_quoted_message() {
        this.call_void.begin(Util.JS.callable("deleteQuotedMessage"), null);
    }

    /**
     * Determines if the editor content contains an attachment keyword.
     */
    public async bool? contains_attachment_keywords(string keyword_spec,
                                                    string subject) {
        try {
            return yield call_returning<bool?>(
                Util.JS.callable("containsAttachmentKeyword")
                .string(keyword_spec)
                .string(subject),
                null
            );
        } catch (Error err) {
            debug("Error checking or attachment keywords: %s", err.message);
            return false;
        }
    }

    /**
     * Cleans the editor content ready for sending.
     *
     * This modifies the DOM, so there's no going back after calling
     * this.
     */
    public async void clean_content() throws Error {
        this.call_void.begin(Util.JS.callable("cleanContent"), null);
    }

    /**
     * Returns the editor text as RFC 3676 format=flowed text.
     */
    public async string? get_text() throws Error {
        const int MAX_BREAKABLE_LEN = 72; // F=F recommended line limit
        const int MAX_UNBREAKABLE_LEN = 998; // SMTP line limit

        string? body_text = yield call_returning<string?>(
            Util.JS.callable("getText"), null
        );
        string[] lines = (body_text ?? "").split("\n");
        GLib.StringBuilder flowed = new GLib.StringBuilder.sized(body_text.length);
        foreach (string line in lines) {
            // Strip trailing whitespace, so it doesn't look like a
            // flowed line.  But the signature separator "-- " is
            // special, so leave that alone.
            if (line != "-- ")
                line = line.chomp();

            // Determine quoting depth by counting the the number of
            // QUOTE_MARKERs present, and build a quote prefix for it.
            int quote_level = 0;
            while (line[quote_level] == Convey.RFC822.Utils.QUOTE_MARKER)
                quote_level += 1;
            line = line[quote_level:line.length];
            string prefix = quote_level > 0 ? string.nfill(quote_level, '>') + " " : "";

            // Check to see if the line (with quote prefix) is longer
            // than the recommended limit, if so work out where to do
            int max_breakable = MAX_BREAKABLE_LEN - prefix.length;
            int max_unbreakable = MAX_UNBREAKABLE_LEN - prefix.length;
            do {
                int start_ind = 0;

                // Space stuff if needed
                if (quote_level == 0 &&
                    (line.has_prefix(">") || line.has_prefix("From"))) {
                    line = " " + line;
                    start_ind = 1;
                }

                // Check to see if we need to break the line, if so
                // determine where to do it.
                int cut_ind = line.length;
                if (cut_ind > max_breakable) {
                    // Line needs to be broken, look for the last
                    // useful place to break before before the
                    // max recommended length.
                    string beg = line[0:max_breakable];
                    cut_ind = beg.last_index_of(" ", start_ind) + 1;
                    if (cut_ind == 0) {
                        // No natural places to break found, so look
                        // for place further along, and if that is
                        // also not found then break on the SMTP max
                        // line length.
                        cut_ind = line.index_of(" ", start_ind) + 1;
                        if (cut_ind == 0)
                            cut_ind = line.length;
                        if (cut_ind > max_unbreakable)
                            cut_ind = max_unbreakable;
                    }
                }

                // Actually break the line
                flowed.append(prefix + line[0:cut_ind] + "\n");
                line = line[cut_ind:line.length];
            } while (line.length > 0);
        }

        return flowed.str;
    }

    private string get_internal_html(string body,
                                     string quote,
                                     bool top_posting,
                                     bool body_complete) {
        StringBuilder html = new StringBuilder();
        string body_class = (this.is_rich_text) ? "" : "plain";
        html.append(HTML_PRE.printf(body_class));
        if (!body_complete) {
            html.append(BODY_PRE.printf(BODY_HTML_ID));
            bool have_body = !Convey.String.is_empty(body);
            if (have_body) {
                html.append(body);
                html.append(SPACER);
            }

            if (!top_posting && !Convey.String.is_empty(quote)) {
                html.append(quote);
                html.append(SPACER);
            }

            html.append(CURSOR);
            html.append(BODY_POST.printf(SIGNATURE_HTML_ID));

            if (top_posting && !Convey.String.is_empty(quote)) {
                html.append_printf(QUOTE, QUOTE_HTML_ID, quote);
            }
        } else {
            html.append(body);
        }
        html.append(HTML_POST);
        return (string) html.data;
    }

    private void on_scrolled(GLib.Variant? parameters) {
        if (parameters != null &&
            parameters.is_container() &&
            parameters.n_children() == 2) {
            GLib.Variant at_top = parameters.get_child_value(0);
            GLib.Variant at_bottom = parameters.get_child_value(1);
            if (at_top.classify() == BOOLEAN) {
                this.body_at_top = at_top.get_boolean();
            }
            if (at_bottom.classify() == BOOLEAN) {
                this.body_at_bottom = at_bottom.get_boolean();
            }
        }
    }

    private void on_cursor_context_changed(GLib.Variant? parameters) {
        if (parameters != null && parameters.classify() == STRING) {
            cursor_context_changed(new EditContext(parameters as string));
        } else {
            warning("Could not get text cursor style");
        }
    }

    /**
     *  Handle a dropped image
     */
    private void on_drag_drop_received(GLib.Variant? parameters) {
        var dict = new GLib.VariantDict(parameters);

        // Files dragged from a file manager arrive as a URI; read them
        // natively rather than via an in-page File object.
        var uri_value = dict.lookup_value("uri", GLib.VariantType.STRING);
        if (uri_value != null) {
            image_uri_dropped(uri_value.get_string());
            return;
        }

        string file_name = dict.lookup_value(
            "fileName", GLib.VariantType.STRING
        ).get_string();
        string file_name_unescaped = GLib.Uri.unescape_string(file_name);

        string file_type = dict.lookup_value(
            "fileType", GLib.VariantType.STRING
        ).get_string();

        string content_base64 = dict.lookup_value(
            "content", GLib.VariantType.STRING
        ).get_string();
        uint8[] image = GLib.Base64.decode(content_base64);

        if (image.length == 0) {
            warning("%s is empty", file_name);
            return;
        }

        // A simple check to see if the file looks like an image. A problem here
        // will be this accepting types which won't be supported by WebKit
        // or recipients.
        if (file_type.index_of("image/") == 0) {
            image_file_dropped(file_name_unescaped, file_type, image);
        }
    }
}
