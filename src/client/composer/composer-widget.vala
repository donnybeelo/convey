/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2017-2021 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

private errordomain AttachmentError {
    FILE,
    DUPLICATE
}

/**
 * A widget for editing an email message.
 *
 * Composers must always be placed in an instance of {@link
 * Container}.
 */
[GtkTemplate (ui = "/net/donnybeelo/Convey/composer-widget.ui")]
public class Composer.Widget : Adw.Bin, Convey.BaseInterface {


    /**
     * The email fields the composer requires for context email.
     *
     * @see load_context
     */
    public const Convey.Email.Field REQUIRED_FIELDS = ENVELOPE | HEADER | BODY;

    /// Translators: Title for an empty composer window
    private const string DEFAULT_TITLE = _("New Message");

    /**
     * Determines the type of the context email passed to the composer
     *
     * @see context_type
     * @see load_context
     */
    public enum ContextType {
        /** No context mail was provided. */
        NONE,

        /** Context is an email to edited, for example a draft or template. */
        EDIT,

        /** Context is an email being replied to the sender only. */
        REPLY_SENDER,

        /** Context is an email being replied to all recipients. */
        REPLY_ALL,

        /** Context is an email being replied to its mailing list. */
        REPLY_LIST,

        /** Context is an email being forwarded. */
        FORWARD
    }

    /**
     * Determines the result of prompting whether to close the composer.
     *
     * @see conditional_close
     */
    public enum CloseStatus {

        /** The composer is already closed. */
        CLOSED,

        /** The composer is ready to be closed, but is not yet. */
        READY,

        /** Closing the composer was not confirmed by a human. */
        CANCELLED;

    }

    /** Defines different supported user interface modes. */
    public enum PresentationMode {

        /** Composer has been closed. */
        CLOSED,

        /** Composer is not currently visible. */
        NONE,

        /**
         * Composer is in its own window, not in a main windows.
         *
         * @see Window
         */
        DETACHED,

        /**
         * Composer is in a full-height box in a main window.
         *
         * @see Box
         */
        PANED,

        /**
         * Composer is embedded inline in a conversation.
         *
         * @see Embed
         */
        INLINE,

        /**
         * Composer is embedded inline with header fields hidden.
         *
         * @see Embed
         */
        INLINE_COMPACT;

    }

    private enum AttachPending { ALL, INLINE_ONLY }

    private enum DraftPolicy { DISCARD, KEEP }

    private class FromAddressMap : GLib.Object {
        public Application.AccountContext account;
        public Convey.RFC822.MailboxAddresses from;

        // Label shown in the From row and its dropdown list
        public string display {
            owned get {
                string display = this.from.to_full_display();
                if (!is_primary()) {
                    // Displayed in the From dropdown to indicate an
                    // "alternate email address" for an account.  The
                    // first printf argument will be the alternate
                    // email address, and the second will be the
                    // account's primary email address.
                    var info = this.account.account.information;
                    display = _("%1$s via %2$s").printf(
                        display, info.display_name
                    );
                }
                return display;
            }
        }

        public FromAddressMap(Application.AccountContext account,
                              Convey.RFC822.MailboxAddresses from) {
            this.account = account;
            this.from = from;
        }

        public bool is_primary() {
            return this.account.account.information.primary_mailbox == this.from[0];
        }
    }

    // A separate composer close action is needed in addition to the
    // default window close action so we can bind Esc to it without
    // also binding the default window close action to Esc as
    // well. This could probably be fixed by pulling both the main
    // window's and composer's actions out of the 'win' action
    // namespace, leaving only common window actions there.
    private const string ACTION_ADD_ATTACHMENT = "add-attachment";
    private const string ACTION_ADD_ORIGINAL_ATTACHMENTS = "add-original-attachments";
    private const string ACTION_CLOSE = "composer-close";
    private const string ACTION_DETACH = "detach";
    private const string ACTION_DISCARD = "discard";
    private const string ACTION_ENCRYPT = "encrypt";
    private const string ACTION_SEND = "send";
    private const string ACTION_SHOW_EXTENDED_HEADERS = "show-extended-headers";

    private const ActionEntry[] ACTIONS = {
        { Action.Window.CLOSE,             on_close                         },
        { Action.Window.SHOW_HELP_OVERLAY, on_show_help_overlay             },
        { Action.Window.SHOW_MENU,         on_show_window_menu              },
        { ACTION_ADD_ATTACHMENT,           on_add_attachment                },
        { ACTION_ADD_ORIGINAL_ATTACHMENTS, on_pending_attachments           },
        { ACTION_CLOSE,                    on_close                         },
        { ACTION_DETACH,                   on_detach                        },
        { ACTION_DISCARD,                  on_discard                       },
        { ACTION_ENCRYPT,                  on_toggle_action, null, "false",
                                           on_encrypt_toggled               },
        { ACTION_SEND,                     on_send                          },
        { ACTION_SHOW_EXTENDED_HEADERS,    on_toggle_action, null, "false",
                                           on_show_extended_headers_toggled },
    };


    static construct {
        set_css_name("convey-composer-widget");

        typeof(AddressesRow).ensure();
        typeof(FromAddressMap).ensure();
    }

    public static void add_accelerators(Application.Client application) {
        application.add_window_accelerators(ACTION_ADD_ATTACHMENT, { "<Ctrl>t" } );
        application.add_window_accelerators(ACTION_DETACH, { "<Ctrl>d" } );
    }

    private const string DRAFT_SAVED_TEXT = _("Saved");
    private const string DRAFT_SAVING_TEXT = _("Saving");
    private const string DRAFT_ERROR_TEXT = _("Error saving");
    // Translators: Shown in the composer when the account's server
    // cannot store drafts at all, so none will be saved.
    private const string DRAFT_UNSUPPORTED_TEXT = _("Drafts not supported");
    private const string BACKSPACE_TEXT = _("Press Backspace to delete quote");

    private const string URI_LIST_MIME_TYPE = "text/uri-list";
    private const string FILE_URI_PREFIX = "file://";

    private const string MAILTO_URI_PREFIX = "mailto:";

    // Keep these in sync with the next const below.
    private const string ATTACHMENT_KEYWORDS =
        "attach|attaching|attaches|attachment|attachments|attached|enclose|enclosed|enclosing|encloses|enclosure|enclosures";
    // Translators: This is list of keywords, separated by pipe ("|")
    // characters, that suggest an attachment; since this is full-word
    // checking, include all variants of each word. No spaces are
    // allowed. The words will be converted to lower case based on
    // locale and English versions included automatically.
    private const string ATTACHMENT_KEYWORDS_LOCALISED =
        _("attach|attaching|attaches|attachment|attachments|attached|enclose|enclosed|enclosing|encloses|enclosure|enclosures");

    private const string PASTED_IMAGE_FILENAME_TEMPLATE = "convey-pasted-image-%u.png";

    /** The account the email is being sent from. */
    public Application.AccountContext sender_context { get; private set; }

    /** The identifier of the saved email this composer holds, if any. */
    public Convey.EmailIdentifier? saved_id {
        get; private set; default = null;
    }

    /** Determines the type of the context email. */
    public ContextType context_type { get; private set; default = NONE; }

    /** Determines the composer's current presentation mode. */
    public PresentationMode current_mode { get; set; default = NONE; }

    /** Determines if the composer is completely empty. */
    public bool is_blank {
        get {
            return this.to_row.is_empty
                && this.cc_row.is_empty
                && this.bcc_row.is_empty
                && this.reply_to_row.is_empty
                && this.subject_row.text.length == 0
                && this.editor.body.is_empty
                && this.attached_files.size == 0;
        }
    }

    /** The email body editor widget. */
    public Editor editor { get; private set; }

    /**
     * The last focused text input widget.
     *
     * This may be a Gtk.Entry if an address field or the subject was
     * most recently focused, or the {@link editor} if the body was
     * most recently focused.
     */
    public Gtk.Widget? focused_input_widget { get; private set; default = null; }

    /** Determines if the composer can send the message. */
    public bool can_send {
        get {
            return this._can_send;
        }
        set {
            this._can_send = value;
            validate_send_button();
        }
    }
    private bool _can_send = true;

    private bool sender_required = false;

    /** Currently selected sender mailbox. */
    public Convey.RFC822.MailboxAddresses from { get; private set; }

    /** Current text of the `to` entry. */
    public string to {
        get { return this.to_row.text; }
        private set { this.to_row.text = value; }
    }

    /** Current text of the `cc` entry. */
    public string cc {
        get { return this.cc_row.text; }
        private set { this.cc_row.text = value; }
    }

    /** Current text of the `bcc` entry. */
    public string bcc {
        get { return this.bcc_row.text; }
        private set { this.bcc_row.text = value; }
    }

    /** Current text of the `reply-to` entry. */
    public string reply_to {
        get { return this.reply_to_row.text; }
        private set { this.reply_to_row.text = value; }
    }

    /** Current text of the `sender` entry. */
    public string subject {
        get { return this.subject_row.text; }
        private set { this.subject_row.text = value; }
    }

    /** The In-Reply-To header value for the composed email, if any. */
    public Convey.RFC822.MessageIDList in_reply_to {
        get; private set; default = new Convey.RFC822.MessageIDList();
    }

    /** The References header value for the composed email, if any. */
    public Convey.RFC822.MessageIDList references {
        get; private set; default = new Convey.RFC822.MessageIDList();
    }

    /** Overrides for the draft folder as save destination, if any. */
    internal Convey.Folder? save_to { get; private set; default = null; }

    internal Composer.Header header { get; private set; }

    internal bool has_multiple_from_addresses {
        get {
            return (
                this.application.get_account_contexts().size > 1 ||
                this.sender_context.account.information.has_sender_aliases
            );
        }
    }

    [GtkChild] private unowned Gtk.Box header_container;
    [GtkChild] private unowned Adw.Bin editor_bin;

    [GtkChild] private unowned Gtk.Box email_headers;
    [GtkChild] private unowned Gtk.ToggleButton show_extended_headers;
    [GtkChild] private unowned Gtk.ToggleButton encrypt_button;

    private bool extended_headers_shown = false;

    [GtkChild] private unowned Adw.ComboRow from_row;
    [GtkChild] private unowned Gtk.Image from_warning;
    [GtkChild] private unowned GLib.ListStore from_model;

    [GtkChild] private unowned AddressesRow to_row;
    [GtkChild] private unowned AddressesRow cc_row;
    [GtkChild] private unowned AddressesRow bcc_row;
    [GtkChild] private unowned AddressesRow reply_to_row;
    [GtkChild] private unowned Adw.EntryRow subject_row;

    [GtkChild] private unowned Gtk.Box attachments_box;
    [GtkChild] private unowned Gtk.DropTarget attachment_drop_target;
    [GtkChild] private unowned Gtk.Box hidden_on_attachment_drag_over;
    [GtkChild] private unowned Gtk.Box visible_on_attachment_drag_over;
    [GtkChild] private unowned Gtk.Widget hidden_on_attachment_drag_over_child;
    [GtkChild] private unowned Gtk.Widget visible_on_attachment_drag_over_child;

    private GLib.SimpleActionGroup actions = new GLib.SimpleActionGroup();

    private bool is_modified {
        get {
            return get_editable_state() != this.loaded_state ||
                !this.editor.body.is_empty;
        }
    }

    /** Determines if the composer can currently save a draft. */
    private bool can_save {
        get { return this.draft_manager != null; }
    }

    /** Determines if current message should be saved as draft. */
    private bool should_save {
        get {
            return this.can_save
                && !this.is_draft_saved
                && !this.is_blank;
        }
    }

    private bool is_attachment_overlay_visible = false;
    private bool top_posting = true;

    // The message(s) this email is in reply to/forwarded from
    private Gee.Set<Convey.EmailIdentifier> referred_ids =
        new Gee.HashSet<Convey.EmailIdentifier>();

    private Gee.List<Convey.Attachment>? pending_attachments = null;
    private AttachPending pending_include = AttachPending.INLINE_ONLY;
    private Gee.Map<string,bool> pgp_keys = new Gee.HashMap<string,bool>();
    private Gee.Set<string> pgp_looked_up = new Gee.HashSet<string>();
    private bool encrypt_set_by_user = false;
    private bool pgp_available = false;
    private bool reply_encrypted = false;
    private uint pgp_check_id = 0;
    private Gee.Set<File> attached_files =new Gee.HashSet<File>(Convey.Files.nullable_hash,
        Convey.Files.nullable_equal);
    private Gee.Map<string,Convey.Memory.Buffer> inline_files = new Gee.HashMap<string,Convey.Memory.Buffer>();
    private Gee.Map<string,Convey.Memory.Buffer> cid_files = new Gee.HashMap<string,Convey.Memory.Buffer>();

    private Convey.App.DraftManager? draft_manager = null;
    private GLib.Cancellable? draft_manager_opening = null;
    private Convey.TimeoutManager draft_timer;
    private bool is_draft_saved = false;
    private string loaded_state = "";
    private string draft_status_text {
        get { return this._draft_status_text; }
        set {
            this._draft_status_text = value;
            update_info_label();
        }
    }
    private string _draft_status_text = "";

    private bool can_delete_quote {
        get { return this._can_delete_quote; }
        set {
            this._can_delete_quote = value;
            update_info_label();
        }
    }
    private bool _can_delete_quote = false;

    private Container? container {
        get { return this.parent as Container; }
    }

    private ApplicationInterface application;

    private Application.Configuration config;


    internal Widget(ApplicationInterface application,
                    Application.Configuration config,
                    Application.AccountContext initial_account,
                    Convey.Folder? save_to = null) {
        base_ref();
        this.application = application;
        this.config = config;
        this.sender_context = initial_account;
        this.save_to = save_to;

        this.header = new Header(config);
        this.header.expand_composer.connect(on_expand_compact_headers);
        // Hide until we know we can save drafts
        this.header.show_save_and_close = false;

        // Setup drag 'n drop
        this.visible_on_attachment_drag_over.remove(
            this.visible_on_attachment_drag_over_child
        );

        this.from_row.notify["selected"].connect(on_envelope_changed);
        this.notify["from"].connect(() => { this.update_pgp_available.begin(); });
        setup_from_popover();

        this.to_row.changed.connect(on_envelope_changed);
        this.cc_row.changed.connect(on_envelope_changed);
        this.bcc_row.changed.connect(on_envelope_changed);
        this.reply_to_row.changed.connect(on_envelope_changed);


        // The drop target declared in the .ui has no accepted types, so
        // GtkDropTarget never negotiates file data. Configure it to
        // accept dropped files (one or many) for attaching.
        this.attachment_drop_target.set_gtypes(
            { typeof(Gdk.FileList), typeof(GLib.File) }
        );
        this.attachment_drop_target.actions = Gdk.DragAction.COPY;

        this.editor = new Editor(config, application.get_web_cache_dir());
        this.editor.insert_image.connect(
            (from_clipboard) => {
                if (from_clipboard) {
                    paste_image();
                } else {
                    insert_image();
                }
            }
        );
        this.editor.body.content_loaded.connect(on_content_loaded);
        this.editor.body.document_modified.connect(() => { draft_changed(); });
        Gtk.EventControllerKey editor_key_controller = new Gtk.EventControllerKey();
        editor_key_controller.key_pressed.connect(on_editor_key_pressed);
        this.editor.body.add_controller(editor_key_controller);

        // Intercept Ctrl+V before the WebView's own paste handler so a
        // clipboard image can be inserted as an inline attachment. The
        // WebView consumes Ctrl+V for text paste, so the paste action's
        // accelerator never fires here.
        Gtk.EventControllerKey paste_key_controller = new Gtk.EventControllerKey();
        paste_key_controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        paste_key_controller.key_pressed.connect(on_editor_capture_key_pressed);
        this.editor.body.add_controller(paste_key_controller);

        for (var child = this.editor.body.get_first_child();
             child != null;
             child = child.get_next_sibling()) {
            if (child is Gtk.TextView) {
                var emoji_shortcut = new Gtk.ShortcutController();
                emoji_shortcut.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
                emoji_shortcut.add_shortcut(new Gtk.Shortcut(
                    Gtk.ShortcutTrigger.parse_string(
                        "<Control>period|<Control>semicolon"
                    ),
                    new Gtk.SignalAction("insert-emoji")
                ));
                child.add_controller(emoji_shortcut);
            }
        }

        this.editor_bin.child = this.editor;

        // WebKitGTK does not forward OS file drags to the page's DOM, so
        // the page's own drop handling never fires. Handle drops onto the
        // body at the GTK level instead, inserting images inline at the
        // drop point.
        var body_drop_target = new Gtk.DropTarget(
            typeof(Gdk.FileList), Gdk.DragAction.COPY
        );
        body_drop_target.set_gtypes(
            { typeof(Gdk.FileList), typeof(GLib.File) }
        );
        // While dragging over the body, show the attachment overlay too
        // so the user can see they can drop above to attach instead of
        // inlining, and move the caret to follow the pointer so they can
        // see where an inline image would land.
        body_drop_target.enter.connect((x, y) => {
            show_attachment_overlay(true);
            this.editor.body.set_cursor_at_point(x, y);
            return Gdk.DragAction.COPY;
        });
        body_drop_target.motion.connect((x, y) => {
            this.editor.body.set_cursor_at_point(x, y);
            return Gdk.DragAction.COPY;
        });
        body_drop_target.leave.connect(() => {
            show_attachment_overlay(false);
        });
        body_drop_target.drop.connect(on_body_drop);
        this.editor.body.add_controller(body_drop_target);

        // Listen to account signals to update from menu.
        this.application.account_available.connect(
            on_account_available
        );
        this.application.account_unavailable.connect(
            on_account_unavailable
        );

        // Listen for drag and dropped image file
        this.editor.body.image_file_dropped.connect(
            on_image_file_dropped
        );
        this.editor.body.image_uri_dropped.connect(on_image_uri_dropped);

        // TODO: also listen for account updates to allow adding identities while writing an email

        this.from = new Convey.RFC822.MailboxAddresses.single(
            this.sender_context.account.information.primary_mailbox
        );

        this.draft_timer = new Convey.TimeoutManager.seconds(
            10, on_draft_timeout
        );

        // Add actions once every element has been initialized and added
        // Composer actions
        this.actions.add_action_entries(ACTIONS, this);
        this.actions.change_action_state(
            ACTION_SHOW_EXTENDED_HEADERS, false
        );
        // Main actions use the window prefix so they override main
        // window actions. But for some reason, we can't use the same
        // prefix for the headerbar.
        insert_action_group(Action.Window.GROUP_NAME, this.actions);
        this.header.headerbar.insert_action_group("cmh", this.actions);
        validate_send_button();

        load_entry_completions();
    }

    ~Widget() {
        base_unref();
    }

    /** Loads an empty message into the composer. */
    public async void load_empty_body(Convey.RFC822.MailboxAddress? to = null)
        throws GLib.Error {
        if (to != null) {
            this.to = to.to_full_display();
            update_extended_headers();
        }
        yield finish_loading("", "", false);
    }

    /** Clears the From row until the user picks a sender. */
    public void require_sender() {
        this.sender_required = true;
        this.from_row.selected = Gtk.INVALID_LIST_POSITION;
        this.from_row.remove_css_class("property");
        this.from_row.add_css_class("warning");
        this.from_warning.visible = true;
        validate_send_button();
    }

    /** Loads a mailto: URL into the composer. */
    public async void load_mailto(string mailto)
        throws GLib.Error {
        Gee.HashMultiMap<string, string> headers = new Gee.HashMultiMap<string, string>();
        if (mailto.has_prefix(MAILTO_URI_PREFIX)) {
            // Parse the mailto link.
            string? email = null;
            string[] parts = mailto.substring(MAILTO_URI_PREFIX.length).split("?", 2);
            if (parts.length > 0) {
                email = Uri.unescape_string(parts[0]);
            }
            string[] params = parts.length == 2 ? parts[1].split("&") : new string[0];
            foreach (string param in params) {
                string[] param_parts = param.split("=", 2);
                if (param_parts.length == 2) {
                    headers.set(Uri.unescape_string(param_parts[0]).down(),
                        Uri.unescape_string(param_parts[1]));
                }
            }

            // Assemble the headers.
            if (!Convey.String.is_empty_or_whitespace(email) &&
                headers.contains("to")) {
                this.to = "%s,%s".printf(
                    email, Convey.Collection.first(headers.get("to"))
                );
            } else if (!Convey.String.is_empty_or_whitespace(email)) {
                this.to = email;
            } else if (headers.contains("to")) {
                this.to = Convey.Collection.first(headers.get("to"));
            }

            if (headers.contains("cc"))
                this.cc = Convey.Collection.first(headers.get("cc"));

            if (headers.contains("bcc"))
                this.bcc = Convey.Collection.first(headers.get("bcc"));

            if (headers.contains("subject"))
                this.subject = Convey.Collection.first(headers.get("subject"));

            var body = "";
            if (headers.contains("body")) {
                body = Convey.HTML.preserve_whitespace(
                    Convey.HTML.escape_markup(
                        Convey.Collection.first(headers.get("body"))
                    )
                );
            }

            Gee.List<string> attachments = new Gee.LinkedList<string>();
            attachments.add_all(headers.get("attach"));
            attachments.add_all(headers.get("attachment"));
            foreach (string attachment in attachments) {
                try {
                    add_attachment_part(File.new_for_commandline_arg(attachment));
                } catch (Error err) {
                    attachment_failed(err.message);
                }
            }
            yield finish_loading(body, "", false);
            update_extended_headers();
        }
    }

    /**
     * Loads a draft, reply, or forwarded message into the composer.
     *
     * If the given context email does not contain the fields
     * specified by {@link REQUIRED_FIELDS}, it will be loaded from
     * the current account context's store with those.
     */
    public async void load_context(ContextType type,
                                   Convey.Email context,
                                   string? quote)
        throws GLib.Error {
        if (type == NONE) {
            throw new Convey.EngineError.BAD_PARAMETERS(
                "Invalid context type: %s", type.to_string()
            );
        }

        var full_context = context;
        if (!context.fields.is_all_set(REQUIRED_FIELDS)) {
            Gee.Collection<Convey.Email>? email =
                yield this.sender_context.emails.list_email_by_sparse_id_async(
                    Convey.Collection.single(context.id),
                    REQUIRED_FIELDS,
                    NONE,
                    this.sender_context.cancellable
                );
            if (email == null || email.is_empty) {
                throw new Convey.EngineError.INCOMPLETE_MESSAGE(
                    "Unable to load email fields required for composer: %s",
                    context.fields.to_string()
                );
            }
            full_context = Convey.Collection.first(email);
        }

        this.context_type = type;

        if (type == EDIT ||
            type == FORWARD) {
            this.pending_include = AttachPending.ALL;
            this.pending_attachments = full_context.attachments;
        } else if (type == REPLY_SENDER || type == REPLY_ALL || type == REPLY_LIST) {
            var attachments = new Gee.ArrayList<Convey.Attachment>();
            foreach (var attachment in full_context.attachments) {
                if (attachment.content_id == null &&
                    attachment.content_disposition.disposition_type != Convey.Mime.DispositionType.INLINE) {
                    attachments.add(attachment);
                }
            }
            this.pending_attachments = attachments;
            this.pending_include = AttachPending.INLINE_ONLY;
        } else {
            this.pending_attachments = full_context.attachments;
        }

        var body = "";
        var complete_quote = "";
        var body_complete = false;
        switch (type) {
        case EDIT:
            this.saved_id = full_context.id;

            if (full_context.from != null) {
                this.from = full_context.from;
            }
            if (full_context.to != null) {
                this.to_row.addresses = full_context.to;
            }
            if (full_context.cc != null) {
                this.cc_row.addresses = full_context.cc;
            }
            if (full_context.bcc != null) {
                this.bcc_row.addresses = full_context.bcc;
            }
            if (full_context.reply_to != null) {
                this.reply_to_row.addresses = full_context.reply_to;
            }
            if (full_context.in_reply_to != null) {
                this.in_reply_to = this.in_reply_to.concatenate_list(
                    full_context.in_reply_to
                );
            }
            if (full_context.references != null) {
                this.references = this.references.concatenate_list(
                    full_context.references
                );
            }
            if (full_context.subject != null) {
                this.subject = full_context.subject.value ?? "";
            }
            Convey.RFC822.Message message = full_context.get_message();
            if (message.has_html_body()) {
                body = message.get_html_body(null);
                body_complete = body.contains(
                    "id=\"%s\"".printf(WebView.BODY_HTML_ID)
                );
            } else {
                body = message.get_plain_body(true, null);
            }
            yield restore_reply_to_state();
            break;

        case REPLY_SENDER:
        case REPLY_ALL:
        case REPLY_LIST:
            // Set the preferred from address based on the message
            // being replied to
            if (!update_from_address(full_context.to) &&
                !update_from_address(full_context.cc) &&
                !update_from_address(full_context.bcc) &&
                !update_from_address(full_context.from) &&
                this.sender_context.account.information.has_sender_aliases) {
                require_sender();
            }
            this.subject = Convey.RFC822.Utils.create_subject_for_reply(
                full_context
            );
            add_recipients_and_ids(type, full_context);
            complete_quote = Util.Email.quote_email_for_reply(
                full_context, quote, HTML
            );
            if (!Convey.String.is_empty(quote)) {
                this.top_posting = false;
            } else {
                this.can_delete_quote = true;
            }
            break;

        case FORWARD:
            this.subject = Convey.RFC822.Utils.create_subject_for_forward(
                full_context
            );
            if (full_context.message_id != null) {
                this.references = this.references.concatenate_id(
                    full_context.message_id
                );
            }
            complete_quote = Util.Email.quote_email_for_forward(
                full_context, quote, HTML
            );
            this.referred_ids.add(full_context.id);
            break;

        case NONE:
            // no-op
            break;
        }
        update_extended_headers();

        yield finish_loading(body, complete_quote, body_complete);
    }

    /**
     * Returns the emails referred to by the composed email.
     *
     * A referred email is the email this composer is a reply to, or
     * forwarded from. There may be multiple if a composer was already
     * open and another email was replied to.
     */
    public Gee.Set<Convey.EmailIdentifier> get_referred_ids() {
        return this.referred_ids.read_only_view;
    }

    /** Detaches the composer and opens it in a new window. */
    public void detach(Application.Client application) {
        Gtk.Widget? focused_widget = null;
        var old_main = this.container?.top_window as Application.MainWindow;
        if (this.container != null) {
            focused_widget = this.container.top_window.get_focus();
            this.container.close();
        }

        var new_window = new Window(this, application);

        // The composer had taken over the old window's title
        if (old_main != null) {
            old_main.update_title();
        }

        // Workaround a GTK+ crasher, Bug 771812. When the
        // composer is re-parented, its menu_button's popover
        // keeps a reference to the conversation window's
        // viewport, so when that is removed it has a null parent
        // and we crash. To reproduce: Reply inline, detach the
        // composer, then choose a different conversation back in
        // the main window. The workaround here sets a new menu
        // model and hence the menu_button constructs a new
        // popover.
        this.editor.actions.change_action_state(
            Editor.ACTION_TEXT_FORMAT,
            this.config.compose_as_html ? "html" : "plain"
        );

        set_mode(DETACHED);
        new_window.present();

        // If the previously focused widget is in the new composer
        // window then focus that, else focus something useful.
        bool refocus = true;
        if (focused_widget != null) {
            Window? focused_window = focused_widget.get_root() as Window;
            if (new_window == focused_window) {
                focused_widget.grab_focus();
                refocus = false;
            }
        }
        if (refocus) {
            set_focus();
        }
    }

    /**
     * Prompts to close the composer if needed, before closing it.
     *
     * If the composer is already closed no action is taken. If the
     * composer is blank then this method will close the composer,
     * else the composer will either be saved or discarded as needed
     * then closed.
     *
     * The return value specifies whether the composer is being closed
     * or if the prompt was cancelled by a human.
     */
    public async CloseStatus conditional_close(bool should_prompt,
                                               bool is_shutdown = false) {
        CloseStatus status = CLOSED;
        switch (this.current_mode) {
        case PresentationMode.CLOSED:
            // no-op
            break;

        case PresentationMode.NONE:
            status = READY;
            break;

        default:
            if (this.is_blank || (!this.is_modified && this.context_type == EDIT)) {
                this.close.begin(this.is_blank && this.context_type != EDIT);
                // This may be a bit of a lie but will very soon
                // become true.
                status = CLOSED;
            } else if (!this.is_modified) {
                this.discard_and_close.begin();
            } else if (should_prompt) {
                present();
                if (this.can_save) {
                    var dialog = new Adw.AlertDialog(
                        // Translators: This dialog text is displayed to the
                        // user when closing a composer where the options are
                        // Keep, Discard or Cancel.
                        _("Do you want to keep or discard this draft message?"),
                        null);
                    dialog.add_response("cancel", _("_Cancel"));
                    dialog.add_response("keep", _("_Keep"));
                    dialog.add_response("discard", _("_Discard"));
                    dialog.default_response = "keep";
                    dialog.close_response = "cancel";
                    if (is_shutdown)
                        dialog.set_response_appearance("discard", DESTRUCTIVE);
                    string response = yield dialog.choose(this.container.top_window, null);
                    if (response == "cancel") {
                        status = CANCELLED;
                    } else if (response == "keep") {
                        this.save_and_close.begin();
                    } else { // Discard
                        this.discard_and_close.begin();
                    }
                } else {
                    var dialog = new Adw.AlertDialog(
                        // Translators: This dialog text is displayed to the
                        // user when closing a composer where the options are
                        // only Discard or Cancel.
                        _("Do you want to discard this draft message?"),
                        null);
                    dialog.add_response("cancel", _("_Cancel"));
                    dialog.add_response("discard", _("_Discard"));
                    dialog.close_response = "cancel";
                    string response = yield dialog.choose(this.container.top_window, null);
                    if (response == "discard") {
                        this.discard_and_close.begin();
                    } else {
                        status = CANCELLED;
                    }
                }
            } else if (this.can_save) {
                this.save_and_close.begin();
            } else {
                this.discard_and_close.begin();
            }
            break;
        }

        return status;
    }

    /**
     * Closes the composer and any drafts unconditionally.
     *
     * This method disables the composer, closes the draft manager,
     * then destroys the composer itself.
     */
    public async void close(bool discard_draft = false) {
        if (this.current_mode != CLOSED) {
            // this will set current_mode to NONE first
            set_enabled(false);
            this.current_mode = CLOSED;

            if (this.draft_manager_opening != null) {
                this.draft_manager_opening.cancel();
                this.draft_manager_opening = null;
            }

            try {
                yield close_draft_manager(discard_draft ? DraftPolicy.DISCARD : DraftPolicy.KEEP);
            } catch (GLib.Error error) {
                this.application.report_problem(
                    new Convey.AccountProblemReport(
                        this.sender_context.account.information, error
                    )
                );
            }

            destroy();
        }
    }

    public override void dispose() {
        if (this.pgp_check_id != 0) {
            GLib.Source.remove(this.pgp_check_id);
            this.pgp_check_id = 0;
        }
        if (this.draft_manager != null) {
            warning("Draft manager still open on composer destroy");
        }

        this.application.account_available.disconnect(
            on_account_available
        );
        this.application.account_unavailable.disconnect(
            on_account_unavailable
        );
        base.dispose();
    }

    /**
     * Sets whether the composer is able to be used.
     *
     * If disabled, the composer hidden, detached from its container
     * and will stop periodically saving drafts.
     */
    public void set_enabled(bool enabled) {
        this.current_mode = NONE;
        this.set_sensitive(enabled);

        // Need to update this separately since it may be detached
        // from the widget itself.
        this.header.headerbar.set_sensitive(enabled);

        if (enabled) {
            var current_account = this.sender_context.account;
            this.open_draft_manager.begin(
                this.saved_id,
                (obj, res) => {
                    try {
                        this.open_draft_manager.end(res);
                    } catch (GLib.Error error) {
                        this.application.report_problem(
                            new Convey.AccountProblemReport(
                                current_account.information, error
                            )
                        );
                    }
                }
            );
        } else {
            if (this.container != null) {
                this.container.close();
            }
            this.draft_timer.reset();
        }
    }

    /** Overrides the folder used for saving drafts. */
    public void set_save_to_override(Convey.Folder? save_to) {
        this.save_to = save_to;
        this.reopen_draft_manager.begin();
    }

    /**
     * Loads and sets contact auto-complete data for the current account.
     */
    private void load_entry_completions() {
        Application.ContactStore contacts = this.sender_context.contacts;

        this.to_row.contacts = contacts;
        this.cc_row.contacts = contacts;
        this.bcc_row.contacts = contacts;
        this.reply_to_row.contacts = contacts;
    }

    /**
     * Restores the composer's widget state from any replied to messages.
     */
    private async void restore_reply_to_state() {
        Gee.List<Convey.RFC822.MailboxAddress> sender_addresses =
            this.sender_context.account.information.sender_mailboxes;
        var to_addresses = new Convey.RFC822.MailboxAddresses();
        var cc_addresses = new Convey.RFC822.MailboxAddresses();

        bool new_email = true;
        foreach (var mid in this.in_reply_to) {
            Gee.MultiMap<Convey.Email, Convey.FolderPath?>? email_map = null;
            try {
                // TODO: Folder blacklist
                email_map = yield this.sender_context.account
                    .local_search_message_id_async(
                        mid,
                        ENVELOPE,
                        true,
                        null,
                        new Convey.EmailFlags.with(Convey.EmailFlags.DRAFT)
                    );
            } catch (GLib.Error error) {
                warning(
                    "Error restoring edited message state from In-Reply-To: %s",
                    error.message
                );
            }
            if (email_map != null) {
                foreach (var candidate in email_map.get_keys()) {
                    if (candidate.message_id != null &&
                        mid.equal_to(candidate.message_id)) {
                        to_addresses = to_addresses.merge_list(
                            Convey.RFC822.Utils.create_to_addresses_for_reply(
                                candidate, sender_addresses
                            )
                        );
                        cc_addresses = cc_addresses.merge_list(
                            Convey.RFC822.Utils.create_cc_addresses_for_reply_all(
                                candidate, sender_addresses
                            )
                        );
                        this.referred_ids.add(candidate.id);
                        new_email = false;
                    }
                }
            }
        }
        if (!new_email) {
            if (this.cc == "") {
                this.context_type = REPLY_SENDER;
            } else {
                this.context_type = REPLY_ALL;
            }

            bool cc_modified =
                !this.cc_row.addresses.contains_all(cc_addresses);
            bool bcc_modified = this.bcc != "";
            bool reply_to_modified = this.reply_to != "";

            // We're in compact inline mode, but there are modified
            // email addresses, so set us to use plain inline mode
            // instead so the modified addresses can be seen.
            if (this.current_mode == INLINE_COMPACT &&
                (cc_modified || bcc_modified || reply_to_modified)) {
                set_mode(INLINE);
            }

            // If there's a modified header that would normally be
            // hidden, show full fields.
            if (bcc_modified || reply_to_modified) {
                this.actions.change_action_state(
                    ACTION_SHOW_EXTENDED_HEADERS, true
                );
            }
        }
    }

    public void present() {
        this.container.present();
        set_focus();
    }

    public void set_focus() {
        bool header_visible = (
            this.current_mode != INLINE_COMPACT
        );
        if (header_visible && Convey.String.is_empty(to)) {
            this.to_row.grab_focus();
        } else if (header_visible && Convey.String.is_empty(subject)) {
            this.subject_row.grab_focus();
        } else {
            // Need to grab the focus after the content has finished
            // loading otherwise the text caret will not be visible.
            if (this.editor.body.is_content_loaded) {
                this.editor.body.grab_focus();
            } else {
                this.editor.body.content_loaded.connect(() => {
                        this.editor.body.grab_focus();
                    });
            }
        }
    }

    private bool update_from_address(Convey.RFC822.MailboxAddresses? referred_addresses) {
        if (referred_addresses != null) {
            var senders = this.sender_context.account.information.sender_mailboxes;
            var referred = referred_addresses.get_all();
            foreach (Convey.RFC822.MailboxAddress address in senders) {
                if (referred.contains(address)) {
                    this.from = new Convey.RFC822.MailboxAddresses.single(address);
                    return true;
                }
            }
        }
        return false;
    }

    private void on_content_loaded() {
        this.update_signature.begin(null);
        if (this.can_delete_quote) {
            this.editor.body.notify["has-selection"].connect(
                () => { this.can_delete_quote = false; }
            );
        }
    }

    private void show_attachment_overlay(bool visible) {
        if (this.is_attachment_overlay_visible == visible)
            return;

        this.is_attachment_overlay_visible = visible;

        // If we just make the widget invisible, it can still intercept drop signals. So we
        // completely remove it instead.
        if (visible) {
            int height = hidden_on_attachment_drag_over.get_height();
            this.hidden_on_attachment_drag_over.remove(this.hidden_on_attachment_drag_over_child);
            this.visible_on_attachment_drag_over.append(this.visible_on_attachment_drag_over_child);
            this.visible_on_attachment_drag_over.set_size_request(-1, height);
        } else {
            this.hidden_on_attachment_drag_over.append(this.hidden_on_attachment_drag_over_child);
            this.visible_on_attachment_drag_over.remove(this.visible_on_attachment_drag_over_child);
            this.visible_on_attachment_drag_over.set_size_request(-1, -1);
        }
   }

    [GtkCallback]
    private Gdk.DragAction on_drop_target_enter(Gtk.DropTarget drop_target,
                                                double x,
                                                double y) {
        show_attachment_overlay(true);
        return Gdk.DragAction.COPY;
    }

    [GtkCallback]
    private void on_drop_target_leave(Gtk.DropTarget drop_target) {
        show_attachment_overlay(false);
    }

    [GtkCallback]
    private bool on_drop_target_drop(Gtk.DropTarget drop_target, Value val, double x, double y) {
        var files = new Gee.ArrayList<GLib.File>();
        if (val.holds(typeof(Gdk.FileList))) {
            var file_list = (Gdk.FileList) val.get_boxed();
            foreach (unowned GLib.File file in file_list.get_files()) {
                files.add(file);
            }
        } else if (val.holds(typeof(GLib.File))) {
            files.add((GLib.File) val.get_object());
        }

        if (files.is_empty) {
            return false;
        }

        // Files dropped on the attachment zone are always attached.
        // Images dropped into the message body are inserted inline
        // instead, handled separately by the web view's drop handler.
        bool added = false;
        foreach (GLib.File file in files) {
            try {
                add_attachment_part(file);
                added = true;
            } catch (Error err) {
                attachment_failed(err.message);
            }
        }
        if (added) {
            draft_changed();
        }
        return added;
    }

    [GtkCallback]
    private bool on_drop_target_accept(Gtk.DropTarget drop_target, Gdk.Drop drop) {
        return drop.formats.contain_gtype(typeof(Gdk.FileList)) ||
            drop.formats.contain_gtype(typeof(GLib.File)) ||
            drop.formats.contain_mime_type(URI_LIST_MIME_TYPE);
    }

    /** Returns a representation of the current message. */
    public async Convey.ComposedEmail to_composed_email(GLib.DateTime? date_override = null,
                                                       bool for_draft = false) {
        Convey.ComposedEmail email = new Convey.ComposedEmail(
            date_override ?? new DateTime.now_local(),
            from
        ).set_to(
            this.to_row.addresses
        ).set_cc(
            this.cc_row.addresses
        ).set_bcc(
            this.bcc_row.addresses
        ).set_reply_to(
            this.reply_to_row.addresses
        ).set_subject(
            this.subject
        ).set_in_reply_to(
            this.in_reply_to
        ).set_references(
            this.references
        );

        email.attached_files.add_all(this.attached_files);
        email.inline_files.set_all(this.inline_files);
        email.cid_files.set_all(this.cid_files);

        email.img_src_prefix = Components.WebView.INTERNAL_URL_PREFIX;

        try {
            email.body_text = yield this.editor.body.get_text();
            if (for_draft) {
                // Must save HTML even if in plain text mode since we
                // need it to restore body/sig/reply state
                email.body_html = yield this.editor.body.get_html_for_draft();
            } else if (this.editor.body.is_rich_text) {
                email.body_html = yield this.editor.body.get_html();
            }
        } catch (Error error) {
            debug("Error getting composer message body: %s", error.message);
        }

        // User-Agent
        email.mailer = Environment.get_prgname() + "/" + Config.VERSION;
        email.encrypt = !for_draft && get_action(ACTION_ENCRYPT).get_state().get_boolean();
        email.autocrypt = !for_draft && this.pgp_available;

        return email;
    }

    /** Appends an email or fragment quoted into the composer. */
    public void append_to_email(Convey.Email referred,
                                string? to_quote,
                                ContextType type)
        throws Convey.EngineError {
        if (!referred.fields.is_all_set(REQUIRED_FIELDS)) {
            throw new Convey.EngineError.INCOMPLETE_MESSAGE(
                "Required fields not met: %s", referred.fields.to_string()
            );
        }

        if (!this.referred_ids.contains(referred.id)) {
            add_recipients_and_ids(type, referred);
        }

        if (type != NONE && type != EDIT) {
            try {
                if (referred.get_message().has_encrypted_body()) {
                    this.reply_encrypted = true;
                    this.encrypt_set_by_user = true;
                    set_encrypt(true);
                    schedule_pgp_check();
                }
            } catch (GLib.Error err) {
                debug("Unable to check if referred email is encrypted: %s", err.message);
            }
        }

        // Always use reply styling, since forward styling doesn't
        // work for inline quotes
        this.editor.body.insert_html(
            Util.Email.quote_email_for_reply(referred, to_quote, HTML)
        );
    }

    private void add_recipients_and_ids(ContextType type,
                                        Convey.Email referred) {
        Gee.List<Convey.RFC822.MailboxAddress> sender_addresses =
            this.sender_context.account.information.sender_mailboxes;

        Convey.RFC822.MailboxAddresses? list_address =
            type == REPLY_LIST
            ? Convey.RFC822.Utils.get_list_post_address(referred)
            : null;
        if (list_address != null) {
            this.to_row.addresses = Convey.RFC822.Utils.merge_addresses(
                this.to_row.addresses, list_address
            );
        } else {
            // Add the sender to the To address list if needed
            this.to_row.addresses = Convey.RFC822.Utils.merge_addresses(
                this.to_row.addresses,
                Convey.RFC822.Utils.create_to_addresses_for_reply(
                    referred, sender_addresses
                )
            );
        }
        if (type == REPLY_ALL) {
            // Add other recipients to the Cc address list if needed,
            // but don't include any already in the To list.
            this.cc_row.addresses = Convey.RFC822.Utils.remove_addresses(
                Convey.RFC822.Utils.merge_addresses(
                    this.cc_row.addresses,
                    Convey.RFC822.Utils.create_cc_addresses_for_reply_all(
                        referred, sender_addresses
                    )
                ),
                this.to_row.addresses
            );
        }

        // Include the new message's id in the In-Reply-To header
        if (referred.message_id != null) {
            this.in_reply_to = this.in_reply_to.merge_id(
                referred.message_id
            );
        }

        // Merge the new message's references with this
        this.references = this.references.merge_list(
            Convey.RFC822.Utils.reply_references(referred)
        );

        // Include the email in the composer's list of referred email
        this.referred_ids.add(referred.id);
    }

    [GtkCallback]
    private bool on_key_pressed(uint keyval, uint keycode, Gdk.ModifierType state) {
        // The controller runs in the capture phase so this takes
        // precedence over the default key handling, in particular
        // the web view's
        return check_send_on_return(keyval, state);
    }

    /** Updates the composer's top level window and headerbar title. */
    public void update_window_title() {
        string subject = this.subject.strip();
        if (Convey.String.is_empty(subject)) {
            subject = DEFAULT_TITLE;
        }

        if (this.container != null) {
            this.container.top_window.title = subject;
        }
    }

    /* Activate the close action */
    public void activate_close_action() {
        this.actions.activate_action(ACTION_CLOSE, null);
    }

    internal void set_mode(PresentationMode new_mode) {
        this.current_mode = new_mode;
        this.header.set_mode(new_mode);

        switch (new_mode) {
        case PresentationMode.DETACHED:
        case PresentationMode.PANED:
            this.email_headers.set_visible(true);
            this.subject_row.visible = true;
            break;

        case PresentationMode.INLINE:
            this.email_headers.set_visible(true);
            this.subject_row.visible = true;
            break;

        case PresentationMode.INLINE_COMPACT:
            this.email_headers.set_visible(false);
            this.subject_row.visible = false;
            set_compact_header_recipients();
            break;

        case PresentationMode.CLOSED:
        case PresentationMode.NONE:
            // no-op
            break;
        }

        update_from_field();
    }

    internal void embed_header() {
        if (this.header.headerbar.parent == null) {
            this.header_container.append(this.header.headerbar);
            this.header.headerbar.hexpand = true;
            // Not a window titlebar, so no window controls
            this.header.headerbar.show_start_title_buttons = false;
            this.header.headerbar.show_end_title_buttons = false;
        }
    }

    private async void finish_loading(string body,
                                      string quote,
                                      bool is_body_complete) {
        update_attachments_view();
        update_pending_attachments(this.pending_include, true);

        this.editor.body.load_html(
            body,
            quote,
            this.top_posting,
            is_body_complete
        );

        var current_account = this.sender_context.account;
        this.open_draft_manager.begin(
            this.saved_id,
            (obj, res) => {
                try {
                    this.open_draft_manager.end(res);
                } catch (GLib.Error error) {
                    this.application.report_problem(
                        new Convey.AccountProblemReport(
                            current_account.information, error
                        )
                    );
                }
            }
        );
        this.loaded_state = get_editable_state();
    }

    private string get_editable_state() {
        return string.joinv("\n", {
            this.from.to_rfc822_string(),
            this.to,
            this.cc,
            this.bcc,
            this.reply_to,
            this.subject,
            this.attached_files.size.to_string()
        });
    }

    private async bool should_send() {
        if (this.pgp_check_id != 0) {
            GLib.Source.remove(this.pgp_check_id);
            this.pgp_check_id = 0;
        }
        Gee.List<string> missing = yield update_pgp_status();
        if (get_encrypt() && !missing.is_empty) {
            var dialog = new Adw.AlertDialog(
                _("No OpenPGP key found"),
                string.joinv("\n", missing.to_array())
            );
            dialog.add_response("close", _("_Close"));
            yield dialog.choose(this.container.top_window, null);
            return false;
        }

        bool has_subject = !Convey.String.is_empty(subject.strip());
        bool has_attachment = this.attached_files.size > 0;
        bool has_body = true;

        try {
            has_body = !Convey.String.is_empty(
                yield this.editor.body.get_html()
            );
        } catch (Error err) {
            debug("Failed to get message body: %s", err.message);
        }

        string? confirmation = null;
        if (!has_subject && !has_body && !has_attachment) {
            confirmation = _("Send message with an empty subject and body?");
        } else if (!has_subject) {
            confirmation = _("Send message with an empty subject?");
        } else if (!has_body && !has_attachment) {
            confirmation = _("Send message with an empty body?");
        } else if (!has_attachment) {
            var keywords = string.join(
                "|", ATTACHMENT_KEYWORDS, ATTACHMENT_KEYWORDS_LOCALISED
            );
            var contains = yield this.editor.body.contains_attachment_keywords(
                keywords, this.subject
            );
            if (contains != null && contains) {
                confirmation = _("Send message without an attachment?");
            }
        }
        if (confirmation != null) {
            var dialog = new Adw.AlertDialog(confirmation, null);
            dialog.add_response("cancel", _("_Cancel"));
            dialog.add_response("ok", _("_OK"));
            dialog.close_response = "cancel";
            dialog.default_response = "ok";
            dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED);
            string response = yield dialog.choose(this.container.top_window, null);
            return (response == "ok");
        }
        return true;
    }

    // Sends the current message.
    private void on_send() {
        this.should_send.begin((obj, res) => {
                if (this.should_send.end(res)) {
                    this.on_send_async.begin();
                }
            });
    }

    // Used internally by on_send()
    private async void on_send_async() {
        set_enabled(false);

        try {
            yield this.editor.body.clean_content();
            yield this.application.send_composed_email(this);
            yield close_draft_manager(DISCARD);

            if (this.container != null) {
                this.container.close();
            }
        } catch (GLib.Error error) {
            this.application.report_problem(
                new Convey.AccountProblemReport(
                    this.sender_context.account.information, error
                )
            );
        }
    }

    /**
     * Creates and opens the composer's draft manager.
     *
     * Note that since the draft manager may block until a remote
     * connection is open, this method may likewise do so. Hence this
     * method typically needs to be called from the main loop as a
     * background async task using the `begin` async call form.
     */
    private async void open_draft_manager(Convey.EmailIdentifier? editing_draft_id)
        throws GLib.Error {
        if (!this.sender_context.account.information.save_drafts) {
            this.header.show_save_and_close = false;
            return;
        }

        // Cancel any existing opening first
        if (this.draft_manager_opening != null) {
            this.draft_manager_opening.cancel();
        }

        GLib.Cancellable internal_cancellable = new GLib.Cancellable();
        this.sender_context.cancellable.cancelled.connect(
            () => { internal_cancellable.cancel(); }
        );
        this.draft_manager_opening = internal_cancellable;

        Convey.Folder? target = this.save_to;
        if (target == null) {
            target = yield this.sender_context.account.get_required_special_folder_async(
                DRAFTS, internal_cancellable
            );
        }

        Convey.EmailFlags? flags = (
            target.used_as == DRAFTS
            ? new Convey.EmailFlags.with(Convey.EmailFlags.DRAFT)
            : new Convey.EmailFlags()
        );

        bool opened = false;
        try {
            var new_manager = yield new Convey.App.DraftManager(
                this.sender_context.account,
                target,
                flags,
                editing_draft_id,
                internal_cancellable
            );
            new_manager.notify[Convey.App.DraftManager.PROP_DRAFT_STATE]
                .connect(on_draft_state_changed);
            new_manager.notify[Convey.App.DraftManager.PROP_CURRENT_DRAFT_ID]
                .connect(on_draft_id_changed);
            new_manager.fatal
                .connect(on_draft_manager_fatal);
            this.draft_manager = new_manager;
            opened = true;
            debug("Draft manager opened");
        } catch (Convey.EngineError.UNSUPPORTED err) {
            // Tell the user rather than silently never saving. This
            // happens when the drafts folder can't store mail or the
            // IMAP server has no UIDPLUS, so we can't identify the
            // draft we just created in order to replace it later.
            warning(
                "Drafts folder unsupported, no drafts will be saved: %s",
                err.message
            );
            this.draft_status_text = DRAFT_UNSUPPORTED_TEXT;
        } catch (GLib.Error err) {
            this.header.show_save_and_close = false;
            throw err;
        } finally {
            this.draft_manager_opening = null;
        }

        this.header.show_save_and_close = opened;
        if (opened) {
            update_draft_state();
        }
    }

    /**
     * Closes current draft manager, if any, then opens a new one.
     */
    private async void reopen_draft_manager() {
        // Discard the draft, if any, since it may be on a different
        // account
        var current_account = this.sender_context.account;
        try {
            yield close_draft_manager(DISCARD);
            yield open_draft_manager(null);
            if (!this.is_blank) {
                yield save_draft();
            }
        } catch (GLib.Error error) {
            this.application.report_problem(
                new Convey.AccountProblemReport(
                    current_account.information, error
                )
            );
        }
    }

    private async void close_draft_manager(DraftPolicy draft_policy)
        throws GLib.Error {
        var old_manager = this.draft_manager;
        if (old_manager != null) {
            this.draft_timer.reset();

            this.draft_manager = null;
            this.saved_id = null;
            this.draft_status_text = "";

            old_manager.notify[Convey.App.DraftManager.PROP_DRAFT_STATE]
                .disconnect(on_draft_state_changed);
            old_manager.notify[Convey.App.DraftManager.PROP_CURRENT_DRAFT_ID]
                .disconnect(on_draft_id_changed);
            old_manager.fatal.disconnect(on_draft_manager_fatal);

            if (draft_policy == DISCARD) {
                debug("Discarding draft");
                yield old_manager.discard(null);
            }

            yield old_manager.close_async(null);
            debug("Draft manager closed");
        }
    }

    private void update_draft_state() {
        switch (this.draft_manager.draft_state) {
            case Convey.App.DraftManager.DraftState.STORED:
                this.draft_status_text = DRAFT_SAVED_TEXT;
                this.is_draft_saved = true;
            break;

            case Convey.App.DraftManager.DraftState.STORING:
                this.draft_status_text = DRAFT_SAVING_TEXT;
                this.is_draft_saved = true;
            break;

            case Convey.App.DraftManager.DraftState.NOT_STORED:
                this.draft_status_text = "";
                this.is_draft_saved = false;
            break;

            case Convey.App.DraftManager.DraftState.ERROR:
                this.draft_status_text = DRAFT_ERROR_TEXT;
                this.is_draft_saved = false;
            break;

            default:
                assert_not_reached();
        }
    }

    private inline void draft_changed() {
        if (this.should_save) {
            this.draft_timer.start();
        }
        if (this.can_save) {
            // Keep a "not supported" notice on screen; there is no
            // draft manager to replace it with a real status.
            this.draft_status_text = "";
        }
        // can_save depends on the value of this, so reset it after
        // the if test above
        this.is_draft_saved = false;
    }

    // Note that drafts are NOT "linkified."
    private async void save_draft() throws GLib.Error {
        debug("Saving draft");

        // cancel timer in favor of just doing it now
        this.draft_timer.reset();

        if (this.draft_manager != null) {
            Convey.ComposedEmail draft = yield to_composed_email(null, true);
            yield this.draft_manager.update(
                yield new Convey.RFC822.Message.from_composed_email(
                    draft, null, GMime.EncodingConstraint.7BIT, null
                ),
                null,
                null
            );
        }
    }

    private async void save_and_close() {
        set_enabled(false);

        if (this.should_save) {
            try {
                yield save_draft();
            } catch (GLib.Error error) {
                this.application.report_problem(
                    new Convey.AccountProblemReport(
                        this.sender_context.account.information, error
                    )
                );
            }
        }

        // Pass on to the controller so the draft can be re-opened
        // on undo
        if (this.container != null) {
            this.container.close();
        }
        yield this.application.save_composed_email(this);
    }

    private async void discard_and_close() {
        set_enabled(false);

        // Pass on to the controller so the discarded email can be
        // re-opened on undo
        yield this.application.discard_composed_email(this);

        try {
            yield close_draft_manager(DISCARD);
        } catch (GLib.Error error) {
            this.application.report_problem(
                new Convey.AccountProblemReport(
                    this.sender_context.account.information, error
                )
            );
        }

        if (this.container != null) {
            this.container.close();
        }
    }

    private void update_attachments_view() {
        if (this.attached_files.size > 0 )
            attachments_box.show();
        else
            attachments_box.hide();
    }

    // Both adds pending attachments and updates the UI if there are
    // any that were left out, that could have been added manually.
    private bool update_pending_attachments(AttachPending include, bool do_add) {
        bool have_added = false;
        bool manual_enabled = false;
        if (this.pending_attachments != null) {
            foreach(Convey.Attachment part in this.pending_attachments) {
                try {
                    string? content_id = part.content_id;
                    Convey.Mime.DispositionType? type =
                        part.content_disposition.disposition_type;
                    File file = part.file;
                    if (type == Convey.Mime.DispositionType.INLINE) {
                        // We only care about the Content Ids of
                        // inline parts, since we need to display them
                        // in the editor web view. However if an
                        // inline part does not have a CID, it is not
                        // possible to be referenced from an IMG SRC
                        // using a cid: URL anyway, so treat it as an
                        // attachment instead.
                        if (content_id != null) {
                            Convey.Memory.FileBuffer file_buffer = new Convey.Memory.FileBuffer(file, true);
                            this.cid_files[content_id] = file_buffer;
                            this.editor.body.add_internal_resource(
                                content_id, file_buffer
                            );
                        } else {
                            type = Convey.Mime.DispositionType.ATTACHMENT;
                        }
                    }

                    if (type == Convey.Mime.DispositionType.INLINE ||
                        include == AttachPending.ALL) {
                        // The pending attachment should be added
                        // automatically, so add it if asked to and it
                        // hasn't already been added
                        if (do_add &&
                            !this.attached_files.contains(file) &&
                            !this.inline_files.has_key(content_id)) {
                            if (type == Convey.Mime.DispositionType.INLINE) {
                                check_attachment_file(file);
                                Convey.Memory.FileBuffer file_buffer = new Convey.Memory.FileBuffer(file, true);
                                string unused;
                                add_inline_part(file_buffer, content_id, out unused);
                            } else {
                                add_attachment_part(file);
                            }
                            have_added = true;
                        }
                    } else {
                        // The pending attachment should only be added
                        // manually
                        manual_enabled = true;
                    }
                } catch (Error err) {
                    attachment_failed(err.message);
                }
            }
        }

        this.editor.new_message_attach_button.visible = !manual_enabled;
        this.editor.conversation_attach_buttons.visible = manual_enabled;

        return have_added;
    }

    private void add_attachment_part(File target)
        throws AttachmentError {
        FileInfo target_info = check_attachment_file(target);

        if (!this.attached_files.add(target)) {
            throw new AttachmentError.DUPLICATE(
                _("“%s” already attached for delivery.").printf(target.get_path())
                );
        }

        Gtk.Box wrapper_box = new Gtk.Box(VERTICAL, 0);
        this.attachments_box.append(wrapper_box);
        wrapper_box.append(new Gtk.Separator(HORIZONTAL));

        Gtk.Box box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        wrapper_box.append(box);

        /// In the composer, the filename followed by its filesize, i.e. "notes.txt (1.12KB)"
        string label_text = _("%s (%s)").printf(target.get_basename(),
                                                Files.get_filesize_as_string(target_info.get_size()));
        Gtk.Label label = new Gtk.Label(label_text);
        box.append(label);
        label.halign = Gtk.Align.START;
        label.ellipsize = Pango.EllipsizeMode.MIDDLE;
        label.has_tooltip = true;
        label.query_tooltip.connect(Util.Gtk.query_tooltip_label);

        Gtk.Button remove_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
        box.append(remove_button);
        remove_button.clicked.connect(() => remove_attachment(target, wrapper_box));

        update_attachments_view();
    }

    private void add_inline_part(Convey.Memory.Buffer target, string content_id, out string unique_contentid)
        throws AttachmentError {

        const string UNIQUE_RENAME_TEMPLATE = "%s_%02u";

        if (target.size == 0)
            throw new AttachmentError.FILE(
                _("“%s” is an empty file.").printf(content_id)
            );

        // Avoid filename conflicts
        unique_contentid = content_id;
        int suffix_index = 0;
        string unsuffixed_filename = "";
        while (this.inline_files.has_key(unique_contentid)) {
            string[] filename_parts = unique_contentid.split(".");

            // Handle no file extension
            int partindex;
            if (filename_parts.length > 1) {
                partindex = filename_parts.length-2;
            } else {
                partindex = 0;
            }
            if (unsuffixed_filename == "")
                unsuffixed_filename = filename_parts[partindex];
            filename_parts[partindex] = UNIQUE_RENAME_TEMPLATE.printf(unsuffixed_filename, suffix_index++);

            unique_contentid = string.joinv(".", filename_parts);
        }

        this.inline_files[unique_contentid] = target;
        this.editor.body.add_internal_resource(
            unique_contentid, target
        );
    }

    private FileInfo check_attachment_file(File target)
        throws AttachmentError {
        FileInfo target_info;
        try {
            target_info = target.query_info("standard::size,standard::type",
                FileQueryInfoFlags.NONE);
        } catch (Error e) {
            throw new AttachmentError.FILE(
                _("“%s” could not be found.").printf(target.get_path())
            );
        }

        if (target_info.get_file_type() == FileType.DIRECTORY) {
            throw new AttachmentError.FILE(
                _("“%s” is a folder.").printf(target.get_path())
            );
        }

        if (target_info.get_size() == 0){
            throw new AttachmentError.FILE(
                _("“%s” is an empty file.").printf(target.get_path())
            );
        }

        try {
            FileInputStream? stream = target.read();
            if (stream != null)
                stream.close();
        } catch(Error e) {
            debug("File '%s' could not be opened for reading. Error: %s", target.get_path(),
                e.message);

            throw new AttachmentError.FILE(
                _("“%s” could not be opened for reading.").printf(target.get_path())
            );
        }

        return target_info;
    }

    private void attachment_failed(string msg) {
        var dialog = new Adw.AlertDialog(_("Cannot add attachment"), msg);
        dialog.add_response("ok", _("_OK"));
        dialog.add_css_class("error");
        dialog.present(this.container.top_window);
    }

    private void remove_attachment(File file, Gtk.Box box) {
        if (!this.attached_files.remove(file))
            return;

        unowned Gtk.Widget? child = this.attachments_box.get_first_child();
        while (child != null) {
            if (child == box) {
                this.attachments_box.remove(box);
                break;
            }
            child = child.get_next_sibling();
        }

        update_attachments_view();
        update_pending_attachments(this.pending_include, false);
        draft_changed();
    }

    /** Whether the given file looks like an image, by content type. */
    private bool file_is_image(GLib.File file) {
        try {
            var info = file.query_info(
                "standard::content-type", GLib.FileQueryInfoFlags.NONE
            );
            string? content_type = info.get_content_type();
            return content_type != null && content_type.has_prefix("image/");
        } catch (GLib.Error err) {
            return false;
        }
    }

    /** Inserts an image file inline in the message body. */
    private void insert_inline_image_file(GLib.File file) throws GLib.Error {
        check_attachment_file(file);
        var file_buffer = new Convey.Memory.FileBuffer(file, true);
        string content_id = file.get_path() ?? file.get_basename();
        string unique_filename;
        add_inline_part(file_buffer, content_id, out unique_filename);
        this.editor.body.insert_image(
            Components.WebView.INTERNAL_URL_PREFIX + unique_filename
        );
    }

    /** Routes a dropped/pasted file: images go inline, others attach. */
    private bool insert_or_attach_file(GLib.File file) {
        try {
            if (this.editor.body.is_rich_text && file_is_image(file)) {
                insert_inline_image_file(file);
            } else {
                add_attachment_part(file);
            }
            return true;
        } catch (GLib.Error err) {
            attachment_failed(err.message);
            return false;
        }
    }

    /** Reads image/file references from the clipboard and inserts them. */
    private void paste_files_from_clipboard() {
        var clipboard = get_clipboard();
        if (clipboard.formats.contain_gtype(typeof(Gdk.FileList)) ||
            clipboard.formats.contain_gtype(typeof(GLib.File))) {
            var gtype = clipboard.formats.contain_gtype(typeof(Gdk.FileList))
                ? typeof(Gdk.FileList) : typeof(GLib.File);
            clipboard.read_value_async.begin(
                gtype, GLib.Priority.DEFAULT, null, (obj, res) => {
                    try {
                        var val = clipboard.read_value_async.end(res);
                        if (val.holds(typeof(Gdk.FileList))) {
                            foreach (unowned GLib.File f in
                                     ((Gdk.FileList) val.get_boxed()).get_files()) {
                                insert_or_attach_file(f);
                            }
                        } else if (val.holds(typeof(GLib.File))) {
                            insert_or_attach_file((GLib.File) val.get_object());
                        }
                        draft_changed();
                    } catch (GLib.Error err) {
                        attachment_failed(err.message);
                    }
                });
        } else {
            clipboard.read_text_async.begin(null, (obj, res) => {
                try {
                    string? text = clipboard.read_text_async.end(res);
                    if (text != null) {
                        foreach (string line in text.split("\n")) {
                            string uri = line.strip();
                            if (uri != "" && !uri.has_prefix("#")) {
                                insert_or_attach_file(GLib.File.new_for_uri(uri));
                            }
                        }
                        draft_changed();
                    }
                } catch (GLib.Error err) {
                    attachment_failed(err.message);
                }
            });
        }
    }

    /**
     * Handle a pasted image, adding it as an inline attachment
     */
    private void paste_image() {
        // The slow operations here are creating the PNG and, to a lesser extent,
        // requesting the image from the clipboard
        this.editor.start_background_work_pulse();

        var clipboard = get_clipboard();
        clipboard.read_texture_async.begin(null, (obj, res) => {
            try {
                var texture = clipboard.read_texture_async.end(res);
                if (texture == null) {
                    warning("Failed to get image from clipboard");
                    this.editor.stop_background_work_pulse();
                }

                var png_bytes = texture.save_to_png_bytes();
                uint8[] png_data = png_bytes.get_data();
                Convey.Memory.ByteBuffer byte_buffer = new Convey.Memory.ByteBuffer.take(png_data, png_data.length);

                GLib.DateTime time_now = new GLib.DateTime.now();
                string filename = PASTED_IMAGE_FILENAME_TEMPLATE.printf(time_now.hash());

                string unique_filename;
                add_inline_part(byte_buffer, filename, out unique_filename);
                this.editor.body.insert_image(
                    Components.WebView.INTERNAL_URL_PREFIX + unique_filename
                );

                this.editor.stop_background_work_pulse();
            } catch (Error err) {
                warning("Failed to get image from clipboard");
                this.editor.stop_background_work_pulse();
            }
        });
    }

    /**
     * Handle prompting for an inserting images as inline attachments
     */
    private void insert_image() {
        var dialog = new Gtk.FileDialog();
        Gtk.FileFilter filter = new Gtk.FileFilter();
        // Translators: This is the name of the file chooser filter
        // when inserting an image in the composer.
        filter.set_filter_name(_("Images"));
        filter.add_mime_type("image/*");
        var filters = new ListStore(typeof(Gtk.FileFilter));
        filters.append(filter);
        dialog.set_filters(filters);

        dialog.open_multiple.begin(this.container.top_window, null, (obj, res) => {
            try {
                ListModel? files = dialog.open_multiple.end(res);
                if (files == null)
                    return;

                for (uint i = 0; i < files.get_n_items(); i++) {
                    File file = (File) files.get_item(i);
                    check_attachment_file(file);
                    Convey.Memory.FileBuffer file_buffer = new Convey.Memory.FileBuffer(file, true);
                    string path = file.get_path();
                    string unique_filename;
                    add_inline_part(file_buffer, path, out unique_filename);
                    this.editor.body.insert_image(
                        Components.WebView.INTERNAL_URL_PREFIX + unique_filename
                    );
                }
            } catch (Gtk.DialogError.DISMISSED err) {
                debug("Composer: image insert canceled by user");
            } catch (GLib.Error err) {
                attachment_failed(err.message);
            }
        });
    }

    private bool check_send_on_return(uint keyval, Gdk.ModifierType state) {
        bool ret = Gdk.EVENT_PROPAGATE;
        switch (Gdk.keyval_name(keyval)) {
            case "Return":
            case "KP_Enter":
                // always trap Ctrl+Enter/Ctrl+KeypadEnter to prevent
                // the Enter leaking through to the controls, but only
                // send if send is available
                if (Gdk.ModifierType.CONTROL_MASK in state) {
                    this.actions.activate_action(ACTION_SEND, null);
                    ret = Gdk.EVENT_STOP;
                }
            break;
        }
        return ret;
    }

    private void validate_send_button() {
        // To must be valid (and hence non-empty), the other email
        // fields must be either empty or valid.
        get_action(ACTION_SEND).set_enabled(
            this.can_send &&
            !this.sender_required &&
            this.to_row.is_valid &&
            (this.cc_row.is_empty || this.cc_row.is_valid) &&
            (this.bcc_row.is_empty || this.bcc_row.is_valid) &&
            (this.reply_to_row.is_empty || this.reply_to_row.is_valid)
        );

        this.header.show_send = this.can_send;
    }

    private void set_compact_header_recipients() {
        bool tocc = !this.to_row.is_empty && !this.cc_row.is_empty,
            ccbcc = !(this.to_row.is_empty && this.cc_row.is_empty) && !this.bcc_row.is_empty;
        string label = this.to_row.text + (tocc ? ", " : "")
            + this.cc_row.text + (ccbcc ? ", " : "") + this.bcc_row.text;
        StringBuilder tooltip = new StringBuilder();
        if (this.to_row.addresses != null) {
            foreach(Convey.RFC822.MailboxAddress addr in this.to_row.addresses) {
                // Translators: Human-readable version of the RFC 822 To header
                tooltip.append("%s %s\n".printf(_("To:"), addr.to_full_display()));
            }
        }
        if (this.cc_row.addresses != null) {
            foreach(Convey.RFC822.MailboxAddress addr in this.cc_row.addresses) {
                // Translators: Human-readable version of the RFC 822 CC header
                tooltip.append("%s %s\n".printf(_("Cc:"), addr.to_full_display()));
            }
        }
        if (this.bcc_row.addresses != null) {
            foreach(Convey.RFC822.MailboxAddress addr in this.bcc_row.addresses) {
                // Translators: Human-readable version of the RFC 822 BCC header
                tooltip.append("%s %s\n".printf(_("Bcc:"), addr.to_full_display()));
            }
        }
        if (this.reply_to_row.addresses != null) {
            foreach(Convey.RFC822.MailboxAddress addr in this.reply_to_row.addresses) {
                // Translators: Human-readable version of the RFC 822 Reply-To header
                tooltip.append("%s%s\n".printf(_("Reply-To: "), addr.to_full_display()));
            }
        }
        this.header.set_recipients(label, tooltip.str.slice(0, -1));  // Remove trailing \n
    }

    private void on_toggle_action(SimpleAction? action, Variant? param) {
        action.change_state(!action.state.get_boolean());
    }

    private void on_encrypt_toggled(GLib.SimpleAction? action,
                                    GLib.Variant? new_state) {
        this.encrypt_set_by_user = true;
        set_encrypt(new_state.get_boolean());
        schedule_pgp_check();
    }

    private bool get_encrypt() {
        return get_action(ACTION_ENCRYPT).get_state().get_boolean();
    }

    private async void update_pgp_available() {
        bool available = false;
        foreach (var mailbox in this.from) {
            available = yield Convey.RFC822.Utils.has_pgp_secret_key(
                mailbox.address, null
            );
        }
        this.pgp_available = available;
        this.encrypt_button.visible = available;
        set_encrypt(available && this.reply_encrypted);
        schedule_pgp_check();
    }

    private void set_encrypt(bool encrypt) {
        encrypt = encrypt && this.pgp_available;
        get_action(ACTION_ENCRYPT).set_state(encrypt);
        this.encrypt_button.icon_name = encrypt
            ? "changes-prevent-symbolic"
            : "changes-allow-symbolic";
        update_pgp_indicators();
    }

    private void schedule_pgp_check() {
        if (this.pgp_check_id != 0) {
            GLib.Source.remove(this.pgp_check_id);
        }
        this.pgp_check_id = GLib.Timeout.add(500, () => {
            this.pgp_check_id = 0;
            this.update_pgp_status.begin();
            return GLib.Source.REMOVE;
        });
    }

    private async Gee.List<string> update_pgp_status() {
        Composer.AddressesRow[] rows = { this.to_row, this.cc_row, this.bcc_row };
        var addresses = new Gee.ArrayList<string>();
        foreach (var mailbox in this.from) {
            addresses.add(mailbox.address);
        }
        bool has_recipients = false;
        foreach (var row in rows) {
            foreach (var mailbox in row.addresses) {
                addresses.add(mailbox.address);
                has_recipients = true;
            }
        }

        foreach (string address in addresses) {
            if (!this.pgp_keys.has_key(address)) {
                bool found = false;
                try {
                    yield Convey.Nonblocking.Concurrent.global.schedule_async(
                        () => { found = Convey.RFC822.Utils.has_pgp_key(address); },
                        null
                    );
                } catch (GLib.Error err) {
                    debug("OpenPGP key check failed for %s: %s", address, err.message);
                }
                this.pgp_keys[address] = found;
            }
            if (!this.pgp_keys[address] && get_encrypt() &&
                !(address in this.pgp_looked_up)) {
                this.pgp_looked_up.add(address);
                try {
                    this.pgp_keys[address] =
                        yield Convey.RFC822.Utils.discover_pgp_key(address, null);
                } catch (GLib.Error err) {
                    warning("OpenPGP key lookup failed for %s: %s", address, err.message);
                }
            }
        }

        var missing = new Gee.ArrayList<string>();
        foreach (string address in addresses) {
            if (!this.pgp_keys[address] && !(address in missing)) {
                missing.add(address);
            }
        }
        if (!this.encrypt_set_by_user) {
            set_encrypt(has_recipients && missing.is_empty);
        }
        update_pgp_indicators();
        return missing;
    }

    private void update_pgp_indicators() {
        bool encrypt = get_encrypt();
        var missing = new Gee.ArrayList<string>();
        Composer.AddressesRow[] rows = { this.to_row, this.cc_row, this.bcc_row };
        foreach (var row in rows) {
            bool row_missing = false;
            foreach (var mailbox in row.addresses) {
                if (this.pgp_keys.has_key(mailbox.address) &&
                    !this.pgp_keys[mailbox.address]) {
                    row_missing = true;
                    missing.add(mailbox.address);
                }
            }
            if (encrypt && row_missing) {
                row.add_css_class("warning");
            } else {
                row.remove_css_class("warning");
            }
        }

        this.encrypt_button.remove_css_class("accent");
        this.encrypt_button.remove_css_class("warning");
        if (!encrypt) {
            this.encrypt_button.tooltip_text = _("Encrypt with OpenPGP");
        } else if (missing.is_empty) {
            this.encrypt_button.tooltip_text = _("Will be encrypted with OpenPGP");
            this.encrypt_button.add_css_class("accent");
        } else {
            this.encrypt_button.tooltip_text = _("No OpenPGP key for:\n%s").printf(
                string.joinv("\n", missing.to_array())
            );
            this.encrypt_button.add_css_class("warning");
        }
    }

    private void update_extended_headers(bool reorder=true) {
        bool cc = !this.cc_row.is_empty;
        bool bcc = !this.bcc_row.is_empty;
        bool reply_to = !this.reply_to_row.is_empty;

        if (reorder) {
            this.cc_row.visible = cc || this.extended_headers_shown;
            this.bcc_row.visible = bcc || this.extended_headers_shown;
            this.reply_to_row.visible = reply_to || this.extended_headers_shown;
        }

        this.show_extended_headers.visible = !(cc && bcc && reply_to);
    }

    private void on_show_extended_headers_toggled(GLib.SimpleAction? action,
                                                  GLib.Variant? new_state) {
        bool show_extended = new_state.get_boolean();
        action.set_state(show_extended);
        this.extended_headers_shown = show_extended;

        update_extended_headers();

        if (show_extended && this.current_mode == INLINE_COMPACT) {
            set_mode(INLINE);
        }
    }

    private bool on_editor_capture_key_pressed(Gtk.EventControllerKey controller,
                                               uint keyval,
                                               uint keycode,
                                               Gdk.ModifierType state) {
        bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
        bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;

        // Keep undo/redo within the composer body. Without this Ctrl+Z
        // falls through to the window's global undo, which reverses the
        // last mail operation (e.g. un-trashing a message) instead of
        // undoing the edit.
        if (ctrl && (keyval == Gdk.Key.z || keyval == Gdk.Key.Z)) {
            if (shift) {
                this.editor.body.redo();
            } else {
                this.editor.body.undo();
            }
            return Gdk.EVENT_STOP;
        }
        if (ctrl && !shift && (keyval == Gdk.Key.y || keyval == Gdk.Key.Y)) {
            this.editor.body.redo();
            return Gdk.EVENT_STOP;
        }

        bool is_ctrl_v =
            (keyval == Gdk.Key.v || keyval == Gdk.Key.V) &&
            ctrl && !shift;
        if (is_ctrl_v && this.editor.body.is_rich_text) {
            var clipboard = get_clipboard();
            // Raw bitmap image (e.g. a screenshot or "copy image").
            if (clipboard.formats.contain_gtype(typeof(Gdk.Texture))) {
                paste_image();
                return Gdk.EVENT_STOP;
            }
            // An image file copied from a file manager arrives as a file
            // reference; insert it inline rather than letting the view
            // paste its path as a link.
            if (clipboard.formats.contain_gtype(typeof(Gdk.FileList)) ||
                clipboard.formats.contain_gtype(typeof(GLib.File)) ||
                clipboard.formats.contain_mime_type(URI_LIST_MIME_TYPE)) {
                paste_files_from_clipboard();
                return Gdk.EVENT_STOP;
            }
        }
        return Gdk.EVENT_PROPAGATE;
    }

    private bool on_editor_key_pressed(Gtk.EventControllerKey controller,
                                       uint keyval,
                                       uint keycode,
                                       Gdk.ModifierType state) {
        bool is_modifier = ((Gdk.KeyEvent) controller.get_current_event()).is_modifier();
        // Widget's keypress override doesn't receive non-modifier
        // keys when the editor processes them, regardless if true or
        // false is called; this deals with that issue (specifically
        // so Ctrl+Enter will send the message)
        if (!is_modifier) {
            if (check_send_on_return(keyval, state) == Gdk.EVENT_STOP)
                return Gdk.EVENT_STOP;
        }

        if (this.can_delete_quote) {
            this.can_delete_quote = false;
            if (!is_modifier && keyval == Gdk.Key.BackSpace) {
                this.editor.body.delete_quoted_message();
                return Gdk.EVENT_STOP;
            }
        }

        return Gdk.EVENT_PROPAGATE;
    }

    private GLib.SimpleAction? get_action(string action_name) {
        return this.actions.lookup_action(action_name) as GLib.SimpleAction;
    }

    private bool add_account_emails_to_from_model(
        Application.AccountContext other_account,
        bool set_active = false
    ) {
        Convey.AccountInformation info = other_account.account.information;
        foreach (Convey.RFC822.MailboxAddress mailbox in info.sender_mailboxes) {
            var addresses = new Convey.RFC822.MailboxAddresses.single(mailbox);
            var addr_map = new FromAddressMap(other_account, addresses);

            this.from_model.append(addr_map);

            if (!set_active && this.from.equal_to(addresses)) {
                this.from_row.selected = this.from_model.get_n_items() - 1;
                set_active = true;
            }
        }
        return set_active;
    }

    // AdwComboRow anchors its popover to the little arrow at the row
    // end, so it opens as a small menu off to the side. Re-anchor it
    // to the row's full rectangle so it spans the whole bar.
    private void setup_from_popover() {
        var popover = find_popover(this.from_row);
        if (popover == null) {
            return;
        }
        popover.has_arrow = false;
        popover.set_offset(0, 6);
        var current = find_list_view(this.from_row)?.model as Gtk.NoSelection;
        var filter = current?.model as Gtk.SelectionFilterModel;
        foreach (var selection in new Gtk.SingleSelection?[] {
                     filter?.model as Gtk.SingleSelection,
                     find_list_view(popover)?.model as Gtk.SingleSelection
                 }) {
            if (selection != null) {
                selection.autoselect = false;
                selection.can_unselect = true;
            }
        }
        popover.map.connect(() => {
            var parent = popover.get_parent();
            Graphene.Point point = { 0, 0 };
            if (parent == null ||
                !this.from_row.compute_point(parent, { 0, 0 }, out point)) {
                return;
            }
            Gdk.Rectangle target = {
                (int) point.x, (int) point.y,
                this.from_row.get_width(),
                this.from_row.get_height()
            };
            popover.set_pointing_to(target);
            popover.width_request = target.width;
        });
    }

    [GtkCallback]
    private void on_from_item_setup(Gtk.SignalListItemFactory factory, GLib.Object object) {
        unowned var item = (Gtk.ListItem) object;

        var label = new Gtk.Label(null);
        label.hexpand = true;
        label.xalign = 0.0f;
        label.ellipsize = Pango.EllipsizeMode.END;

        var tick = new Gtk.Image.from_icon_name("object-select-symbolic");
        this.from_row.bind_property(
            "selected-item", tick, "visible", GLib.BindingFlags.DEFAULT,
            (binding, from, ref to) => {
                to.set_boolean(from.get_object() == item.item);
                return true;
            }
        );

        var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        box.append(label);
        box.append(tick);
        item.child = box;
    }

    [GtkCallback]
    private void on_from_item_bind(Gtk.SignalListItemFactory factory, GLib.Object object) {
        unowned var item = (Gtk.ListItem) object;
        unowned var label = (Gtk.Label) item.child.get_first_child();
        label.label = ((FromAddressMap) item.item).display;
        label.get_next_sibling().visible = (item.item == this.from_row.selected_item);
    }

    private static Gtk.Popover? find_popover(Gtk.Widget parent) {
        for (var child = parent.get_first_child();
             child != null;
             child = child.get_next_sibling()) {
            var popover = child as Gtk.Popover ?? find_popover(child);
            if (popover != null) {
                return popover;
            }
        }
        return null;
    }

    private static Gtk.ListView? find_list_view(Gtk.Widget parent) {
        for (var child = parent.get_first_child();
             child != null;
             child = child.get_next_sibling()) {
            var list = child as Gtk.ListView ?? find_list_view(child);
            if (list != null) {
                return list;
            }
        }
        return null;
    }

    private void update_info_label() {
        string text = "";
        if (this.can_delete_quote) {
            text = BACKSPACE_TEXT;
        } else {
            text = this.draft_status_text;
        }
        this.editor.set_info_label(text);
    }

    // Updates from combobox contents and visibility, returns true if
    // the from address had to be set
    private bool update_from_field() {
        bool sender_required = this.sender_required;
        this.from_row.visible = false;

        // Don't show in inline unless the current account has
        // multiple email accounts or aliases, since these will be replies to a
        // conversation
        if ((this.current_mode == INLINE ||
             this.current_mode == INLINE_COMPACT) &&
            !this.has_multiple_from_addresses) {
            return false;
        }

        // If there's only one account and it not have any aliases,
        // show nothing.
        Gee.Collection<Application.AccountContext> accounts =
            this.application.get_account_contexts();
        if (accounts.size < 1 ||
            (accounts.size == 1 &&
            !Convey.Collection.first(
                accounts
            ).account.information.has_sender_aliases)) {
            return false;
        }

        this.from_row.visible = true;

        // Always add at least the current account. The var set_active
        // is set to true if the current message's from address has
        // been set in the ComboBox.
        bool set_active = add_account_emails_to_from_model(this.sender_context);
        foreach (var account in accounts) {
            if (account != this.sender_context) {
                set_active = add_account_emails_to_from_model(
                    account, set_active
                );
            }
        }

        if (!set_active) {
            // The identity or account that was active before has been
            // removed use the best we can get now (primary address of
            // the account or any other)
            this.from_row.selected = 0;
        }
        if (sender_required) {
            require_sender();
        }

        this.from_row.notify["selected"].connect((obj, pspec) => { on_from_changed(); });
        return !set_active;
    }

    private void update_from() throws Error {
        FromAddressMap selected = this.from_row.selected_item as FromAddressMap;
        if (selected != null) {
            this.from = selected.from;
            if (this.sender_required) {
                this.sender_required = false;
                this.from_row.remove_css_class("warning");
                this.from_row.add_css_class("property");
                this.from_warning.visible = false;
                validate_send_button();
            }

            if (selected.account != this.sender_context) {
                this.sender_context = selected.account;
                load_entry_completions();

                this.reopen_draft_manager.begin();
            }
            if (this.editor.body.is_content_loaded) {
                this.update_signature.begin(null);
            }
        }
    }

    private async void update_signature(Cancellable? cancellable = null) {
        Convey.AccountInformation account =
            this.sender_context.account.information;
        Convey.RFC822.MailboxAddress? sender = this.from.get(0);
        string sig = sender != null ? account.get_sender_signature(sender) : "";
        if (Convey.String.is_empty_or_whitespace(sig) && account.use_signature) {
            sig = account.signature;
            if (Convey.String.is_empty_or_whitespace(sig)) {
                // No signature is specified in the settings, so use
                // ~/.signature
                File signature_file = File.new_for_path(Environment.get_home_dir()).get_child(".signature");
                try {
                    uint8[] data;
                    yield signature_file.load_contents_async(cancellable, out data, null);
                    sig = (string) data;
                } catch (Error error) {
                    if (!(error is IOError.NOT_FOUND)) {
                        debug("Error reading signature file %s: %s", signature_file.get_path(), error.message);
                    }
                }
            }
        }

        // Still want to update the signature even if it is empty,
        // since when changing the selected from account, if the
        // previously selected account had a sig but the newly
        // selected account does not, the old sig gets cleared out.
        if (Convey.String.is_empty_or_whitespace(sig)) {
            // Clear out multiple spaces etc so smart_escape
            // doesn't create &nbsp;'s
            sig = "";
        }
        this.editor.body.update_signature(
            embed_signature_images(Convey.HTML.smart_escape(sig))
        );
    }

    private string embed_signature_images(string signature) {
        try {
            var data_image = new GLib.Regex(
                "src=\"data:image/([^;\"]+);base64,([^\"]+)\""
            );
            return data_image.replace_eval(
                signature, -1, 0, 0, (info, result) => {
                    uint8[] data = GLib.Base64.decode(info.fetch(2));
                    string name = "signature.%s".printf(
                        info.fetch(1).split("+")[0]
                    );
                    try {
                        string unique_id;
                        add_inline_part(
                            new Convey.Memory.ByteBuffer(data, data.length),
                            name,
                            out unique_id
                        );
                        result.append(
                            "src=\"%s%s\"".printf(
                                Components.WebView.INTERNAL_URL_PREFIX,
                                unique_id
                            )
                        );
                    } catch (AttachmentError err) {
                        result.append(info.fetch(0));
                    }
                    return false;
                }
            );
        } catch (GLib.RegexError err) {
            debug("Couldn't embed signature images: %s", err.message);
            return signature;
        }
    }

    private void on_draft_id_changed() {
        this.saved_id = this.draft_manager.current_draft_id;
    }

    private void on_draft_manager_fatal(Error err) {
        this.draft_status_text = DRAFT_ERROR_TEXT;
    }

    private void on_draft_state_changed() {
        update_draft_state();
    }

    [GtkCallback]
    private void on_subject_changed(Gtk.Editable subject_editable) {
        draft_changed();
        update_window_title();
    }

    private void on_envelope_changed() {
        schedule_pgp_check();
        draft_changed();
        update_extended_headers(false);
        validate_send_button();
    }

    private void on_from_changed() {
        schedule_pgp_check();
        try {
            update_from();
        } catch (Error err) {
            debug("Error updating from address: %s", err.message);
        }
    }

    private void on_expand_compact_headers() {
        set_mode(INLINE);
    }

    private void on_detach() {
        detach(this.container.top_window.application as Application.Client);
    }

    private void on_add_attachment() {
        var dialog = new Gtk.FileDialog();
        dialog.open_multiple.begin(this.container.top_window, null, (obj, res) => {
            try {
                ListModel? files = dialog.open_multiple.end(res);
                if (files == null)
                    return;

                for (uint i = 0; i < files.get_n_items(); i++) {
                    File file = (File) files.get_item(i);
                    add_attachment_part(file);
                    draft_changed();
                }
            } catch (Gtk.DialogError.DISMISSED err) {
                debug("Composer: opening attachment canceled by user");
            } catch (Error err) {
                attachment_failed(err.message);
            }
        });
    }

    private void on_pending_attachments() {
        if (update_pending_attachments(AttachPending.ALL, true)) {
            draft_changed();
        }
    }

    private void on_close() {
        conditional_close.begin(this.container is Window);
    }

    private void on_show_window_menu() {
        Application.MainWindow main = null;
        if (this.container != null) {
            main = this.container.top_window as Application.MainWindow;
        }
        if (main != null) {
            main.show_window_menu();
        }
    }

    private void on_show_help_overlay() {
        var overlay = this.container.top_window.get_help_overlay();
        overlay.section_name = "composer";
        overlay.show();
    }

    private void on_discard() {
        if (this.container is Window) {
            conditional_close.begin(true);
        } else {
            this.discard_and_close.begin();
        }
    }

    private void on_draft_timeout() {
        var current_account = this.sender_context.account;
        this.save_draft.begin(
            (obj, res) => {
                try {
                    this.save_draft.end(res);
                } catch (GLib.Error error) {
                    this.application.report_problem(
                        new Convey.AccountProblemReport(
                            current_account.information, error
                        )
                    );
                }
            }
        );
    }

    private void on_account_available() {
        update_from_field();
    }

    private void on_account_unavailable() {
        if (update_from_field()) {
            on_from_changed();
        }
    }

    /**
     * Handle a dropped image file, adding it as an inline attachment
     */
    private bool on_body_drop(Gtk.DropTarget drop_target, GLib.Value val,
                              double x, double y) {
        var files = new Gee.ArrayList<GLib.File>();
        if (val.holds(typeof(Gdk.FileList))) {
            foreach (unowned GLib.File file in
                     ((Gdk.FileList) val.get_boxed()).get_files()) {
                files.add(file);
            }
        } else if (val.holds(typeof(GLib.File))) {
            files.add((GLib.File) val.get_object());
        }

        bool inserted = false;
        foreach (GLib.File file in files) {
            if (this.editor.body.is_rich_text && file_is_image(file)) {
                // Position the caret where the file was dropped, then
                // insert the image there.
                this.editor.body.set_cursor_at_point(x, y);
                try {
                    insert_inline_image_file(file);
                    inserted = true;
                } catch (GLib.Error err) {
                    attachment_failed(err.message);
                }
            }
        }
        if (inserted) {
            draft_changed();
        }
        return inserted;
    }

    private void on_image_uri_dropped(string uri) {
        var file = GLib.File.new_for_uri(uri);
        if (!file_is_image(file)) {
            return;
        }
        try {
            insert_inline_image_file(file);
            draft_changed();
        } catch (GLib.Error err) {
            attachment_failed(err.message);
        }
    }

    private void on_image_file_dropped(string filename, string file_type, uint8[] contents) {
        Convey.Memory.ByteBuffer buffer = new Convey.Memory.ByteBuffer(contents, contents.length);
        string unique_filename;
        try {
            add_inline_part(buffer, filename, out unique_filename);
        } catch (AttachmentError err) {
            warning("Couldn't attach dropped empty file %s", filename);
            return;
        }

        this.editor.body.insert_image(
            Components.WebView.INTERNAL_URL_PREFIX + unique_filename
        );
    }

}
