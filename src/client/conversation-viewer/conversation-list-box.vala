/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2016,2019 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * A widget for displaying conversations as a list of emails.
 *
 * The view displays the current selected {@link
 * Convey.App.Conversation} from the conversation list. To do so, it
 * listens to signals from both the list and the current conversation
 * monitor, updating the email list as needed.
 *
 * Unlike ConversationListStore (which sorts by date received),
 * ConversationListBox sorts by the {@link Convey.Email.date} field
 * (the Date: header), as that's the date displayed to the user.
 */
public class ConversationListBox : Adw.Bin, Convey.BaseInterface {

    /** Fields that must be available for listing conversation email. */
    public const Convey.Email.Field REQUIRED_FIELDS = (
        // Sorting the conversation
        Convey.Email.Field.DATE |
        // Determine unread/starred, etc
        Convey.Email.Field.FLAGS |
        // Determine if the message is from the sender or not
        Convey.Email.Field.ORIGINATORS
    );

    internal const string EMAIL_ACTION_GROUP_NAME = "eml";

    internal const string ACTION_DELETE = "delete";
    internal const string ACTION_FORWARD = "forward";
    internal const string ACTION_MARK_LOAD_REMOTE = "mark-load-remote";
    internal const string ACTION_MARK_READ = "mark-read";
    internal const string ACTION_MARK_STARRED = "mark-starred";
    internal const string ACTION_MARK_UNREAD = "mark-unread";
    internal const string ACTION_MARK_UNREAD_DOWN = "mark-unread-down";
    internal const string ACTION_MARK_UNSTARRED = "mark-unstarred";
    internal const string ACTION_PRINT = "print";
    internal const string ACTION_REPLY_ALL = "reply-all";
    internal const string ACTION_REPLY_LIST = "reply-list";
    internal const string ACTION_REPLY_SENDER = "reply-sender";
    internal const string ACTION_SAVE_ALL_ATTACHMENTS = "save-all-attachments";
    internal const string ACTION_TRASH = "trash";
    internal const string ACTION_UNSUBSCRIBE = "unsubscribe";
    internal const string ACTION_VIEW_SOURCE = "view-source";
    internal const string ACTION_OPEN_IN_WINDOW = "open-in-window";

    // Offset from the top of the list box which emails views will
    // scrolled to, so the user can see there are additional messages
    // above it. This is approx 0.5 times the height of a collapsed
    // ConversationEmail at default font size; it doesn't account for
    // the user's font size.
    private const int EMAIL_TOP_OFFSET = 32;

    // Amount of time to wait after the user took some action that may
    // be interpreted as marking the email as read before actually
    // checking
    private const int MARK_READ_TIMEOUT_MSEC = 250;

    // Amount of pixels that need to be shown of an email's body to
    // mark it as read
    private const int MARK_READ_PADDING = 50;

    private const string ACTION_TARGET_TYPE = (
        Convey.EmailIdentifier.BASE_VARIANT_TYPE
    );
    private const ActionEntry[] email_action_entries = {
        { ACTION_DELETE, on_email_delete, ACTION_TARGET_TYPE },
        { ACTION_FORWARD, on_email_forward, ACTION_TARGET_TYPE },
        { ACTION_MARK_LOAD_REMOTE, on_email_load_remote, ACTION_TARGET_TYPE },
        { ACTION_MARK_READ, on_email_mark_read, ACTION_TARGET_TYPE },
        { ACTION_MARK_STARRED, on_email_mark_starred, ACTION_TARGET_TYPE },
        { ACTION_MARK_UNREAD, on_email_mark_unread, ACTION_TARGET_TYPE },
        { ACTION_MARK_UNREAD_DOWN, on_email_mark_unread_down, ACTION_TARGET_TYPE },
        { ACTION_MARK_UNSTARRED, on_email_mark_unstarred, ACTION_TARGET_TYPE },
        { ACTION_PRINT, on_email_print, ACTION_TARGET_TYPE },
        { ACTION_REPLY_ALL, on_email_reply_all, ACTION_TARGET_TYPE },
        { ACTION_REPLY_LIST, on_email_reply_list, ACTION_TARGET_TYPE },
        { ACTION_REPLY_SENDER, on_email_reply_sender, ACTION_TARGET_TYPE },
        { ACTION_SAVE_ALL_ATTACHMENTS, on_email_save_all_attachments, ACTION_TARGET_TYPE },
        { ACTION_TRASH, on_email_trash, ACTION_TARGET_TYPE },
        { ACTION_UNSUBSCRIBE, on_email_unsubscribe, ACTION_TARGET_TYPE },
        { ACTION_VIEW_SOURCE, on_email_view_source, ACTION_TARGET_TYPE },
        { ACTION_OPEN_IN_WINDOW, on_email_open_in_window, ACTION_TARGET_TYPE },
    };


    /** Manages find/search term matching in a conversation. */
    public class SearchManager : Convey.BaseObject {


        // The list that owns this manager
        private weak ConversationListBox list;

        // Conversation being managed
        private Convey.App.Conversation conversation;

        // Cached search terms to apply to new messages
        private Gee.Set<string>? terms = null;

        // Total number of search matches found
        private uint matches_found = 0;

        // Cancellable used when highlighting search matches
        private GLib.Cancellable highlight_cancellable = new GLib.Cancellable();


        /** Fired when the number of matching emails has changed. */
        public signal void matches_updated(uint matches);


        internal SearchManager(ConversationListBox list,
                               Convey.App.Conversation conversation) {
            this.list = list;
            this.conversation = conversation;
        }


        /**
         * Loads search term matches for this list's emails.
         */
        public async void highlight_matching_email(Convey.SearchQuery query,
                                                   bool enable_scroll)
            throws GLib.Error {
            cancel();

            // Keep a copy of the current cancellable so it can't get
            // changed out from underneath the execution of this method
            GLib.Cancellable cancellable = this.highlight_cancellable;

            Convey.Account account = this.conversation.base_folder.account;
            Gee.Collection<Convey.EmailIdentifier>? matching =
            yield account.local_search_async(
                query,
                this.conversation.get_count(),
                0,
                null,
                this.conversation.get_email_ids(),
                cancellable
            );

            if (matching != null) {
                Gee.Set<string>? terms =
                    yield account.get_search_matches_async(
                        query, matching, cancellable
                    );

                if (cancellable.is_cancelled()) {
                    throw new GLib.IOError.CANCELLED(
                        "Search term highlighting cancelled"
                    );
                }

                if (terms != null && !terms.is_empty) {
                    this.terms = terms;

                    // Scroll to the first matching row first
                    EmailRow? first = null;
                    foreach (Convey.EmailIdentifier id in matching) {
                        EmailRow? row = this.list.get_email_row_by_id(id);
                        if (row != null &&
                            (first == null || row.get_index() < first.get_index())) {
                            first = row;
                        }
                    }
                    if (first != null && enable_scroll) {
                        this.list.scroll_to_row(first);
                    }

                    // Now expand them all
                    foreach (Convey.EmailIdentifier id in matching) {
                        EmailRow? row = this.list.get_email_row_by_id(id);
                        if (row != null) {
                            apply_terms(row, terms, cancellable);
                            row.expand.begin();
                        }
                    }
                }
            }
        }

        /**
         * Highlights matching terms in the given email row, if any.
         */
        internal void highlight_row_if_matching(EmailRow row) {
            if (this.terms != null) {
                apply_terms(row, this.terms, this.highlight_cancellable);
            }
        }

        /**
         * Removes search term highlighting from all messages.
         */
        public void unmark_terms() {
            cancel();

            for (int i = 0; true; i++) {
                unowned var row = this.list.listbox.get_row_at_index(i) as EmailRow;
                if (row == null)
                    break;

                if (row.is_search_match) {
                    row.is_search_match = false;
                    foreach (ConversationMessage msg_view in row.view) {
                        msg_view.unmark_search_terms();
                    }
                }
            }
        }

        public void cancel() {
            this.highlight_cancellable.cancel();
            this.highlight_cancellable = new Cancellable();
            this.terms = null;
            this.matches_found = 0;
            notify_matches_updated();
        }

        private void apply_terms(EmailRow row,
                                 Gee.Set<string>? terms,
                                 GLib.Cancellable cancellable) {
            if (row.view.message_body_state == COMPLETED) {
                this.apply_terms_impl.begin(
                    row, terms, cancellable, apply_terms_impl_finished
                );
            } else {
                row.view.notify["message-body-state"].connect(() => {
                        this.apply_terms_impl.begin(
                            row, terms, cancellable, apply_terms_impl_finished
                        );
                    });
            }
        }

        // This should only be called from apply_terms above
        private async uint apply_terms_impl(EmailRow row,
                                            Gee.Set<string>? terms,
                                            GLib.Cancellable cancellable)
            throws GLib.IOError.CANCELLED {
            uint count = 0;
            foreach (ConversationMessage view in row.view) {
                if (cancellable.is_cancelled()) {
                    throw new GLib.IOError.CANCELLED(
                        "Applying search terms cancelled"
                    );
                }
                count += yield view.highlight_search_terms(terms, cancellable);
            }

            row.is_search_match = (count > 0);
            return count;
        }

        private void apply_terms_impl_finished(GLib.Object? obj,
                                               GLib.AsyncResult res) {
            try {
                this.matches_found += this.apply_terms_impl.end(res);
                notify_matches_updated();
            } catch (GLib.IOError.CANCELLED err) {
                // All good
            }
        }

        private inline void notify_matches_updated() {
            matches_updated(this.matches_found);
        }

    }


    // Base class for list rows in the list box
    internal abstract class ConversationRow : Gtk.ListBoxRow, Convey.BaseInterface {


        protected const string EXPANDED_CLASS = "convey-expanded";


        // The email being displayed by this row, if any
        public Convey.Email? email { get; private set; default = null; }

        // Is the row showing the email's message body or just headers?
        public bool is_expanded {
            get {
                return this._is_expanded;
            }
            protected set {
                this._is_expanded = value;
                notify_property("is-expanded");
            }
        }
        private bool _is_expanded = false;


        // We can only scroll to a specific row once it has been
        // allocated space. This signal allows the viewer to hook up
        // to appropriate times to try to do that scroll.
        public signal void should_scroll();

        // Emitted when an email is loaded for the first time
        public signal void email_loaded(Convey.Email email);


        protected ConversationRow(Convey.Email? email) {
            base_ref();
            this.email = email;
            add_css_class("card");
            // Clip children (webview, action bars) to the card's
            // rounded corners
            this.overflow = HIDDEN;
            notify["is-expanded"].connect(update_css_class);
            show();
        }

        ~ConversationRow() {
            base_unref();
        }

        // Request the row be expanded, if supported.
        public virtual new async void expand()
            throws GLib.Error {
            // Not supported by default
        }

        // Request the row be collapsed, if supported.
        public virtual void collapse() {
            // Not supported by default
        }

        // Enables firing the should_scroll signal when this row is
        // allocated a size
        public void enable_should_scroll() {
            // GTK4 has no size-allocate signal; poll from the frame
            // clock until the row has a height, then fire once so we
            // don't keep scrolling later (e.g. on window resizes).
            // GTK4 has no size-allocate signal; poll from the frame
            // clock until the row's allocated size and position have
            // settled (the first frame only yields a provisional
            // margins-only allocation at y=0), then fire once so we
            // don't keep scrolling later (e.g. on window resizes).
            int last_height = -1;
            double last_y = -1;
            add_tick_callback(() => {
                var parent = get_parent();
                if (parent == null) {
                    return GLib.Source.CONTINUE;
                }
                Graphene.Point point;
                if (!compute_point(parent, { 0, 0 }, out point)) {
                    return GLib.Source.CONTINUE;
                }
                int height = get_height();
                bool stable = (height > 16 &&
                               height == last_height &&
                               point.y == last_y);
                last_height = height;
                last_y = point.y;
                if (!stable) {
                    return GLib.Source.CONTINUE;
                }
                should_scroll();
                return GLib.Source.REMOVE;
            });
        }

        private void update_css_class() {
            if (this.is_expanded)
                add_css_class(EXPANDED_CLASS);
            else
                remove_css_class(EXPANDED_CLASS);

            update_previous_sibling_css_class();
        }

        private void update_previous_sibling_css_class() {
            var previous_sibling = get_prev_sibling();
            if (previous_sibling != null) {
                if (this.is_expanded)
                    previous_sibling.add_css_class("convey-expanded-previous-sibling");
                else
                    previous_sibling.remove_css_class("convey-expanded-previous-sibling");
            }
        }

        protected inline void set_style_context_class(string class_name, bool value) {
            if (value) {
                add_css_class(class_name);
            } else {
                remove_css_class(class_name);
            }
        }
    }


    // Displays a single ConversationEmail in the list box
    internal class EmailRow : ConversationRow {


        private const string MATCH_CLASS = "convey-matched";


        // Has the row been temporarily expanded to show search matches?
        public bool is_pinned { get; private set; default = false; }

        // Does the row contain an email matching the current search?
        public bool is_search_match {
            get { return has_css_class(MATCH_CLASS); }
            set {
                set_style_context_class(MATCH_CLASS, value);
                this.is_pinned = value;
                update_row_expansion();
            }
        }


        // The email view for this row, if any
        public ConversationEmail view { get; private set; }


        public EmailRow(ConversationEmail view) {
            base(view.email);
            this.view = view;
            this.child = view;
        }

        public override async void expand()
            throws GLib.Error {
            this.is_expanded = true;
            update_row_expansion();
            if (this.view.message_body_state == NOT_STARTED) {
                yield this.view.load_body();
                email_loaded(this.view.email);
            }
        }

        public override void collapse() {
            this.is_expanded = false;
            this.is_pinned = false;
            update_row_expansion();
        }

        private inline void update_row_expansion() {
            if (this.is_expanded || this.is_pinned) {
                this.view.expand_email();
            } else {
                this.view.collapse_email();
            }
        }

    }


    // Displays a loading widget in the list box
    internal class LoadingRow : ConversationRow {


        protected const string LOADING_CLASS = "convey-loading";


        public LoadingRow() {
            base(null);
            add_css_class(LOADING_CLASS);
            this.activatable = false;

            Gtk.Spinner spinner = new Gtk.Spinner();
            spinner.height_request = 16;
            spinner.width_request = 16;
            this.child = spinner;
        }

    }


    // Displays a single embedded composer in the list box
    internal class ComposerRow : ConversationRow {

        // The embedded composer for this row
        public Composer.Embed view { get; private set; }


        public ComposerRow(Composer.Embed view) {
            base(view.referred);
            this.view = view;
            this.is_expanded = true;
            this.child = this.view;

            this.focus_on_click = false;
            // The composer handles its own input; without this the
            // row shows hover/active styling that activates nothing
            this.activatable = false;
        }

    }


    static construct {
        add_shortcut(new Gtk.Shortcut(Gtk.ShortcutTrigger.parse_string("Space"),
                     new Gtk.NamedAction("focus-next")));
        add_shortcut(new Gtk.Shortcut(Gtk.ShortcutTrigger.parse_string("<Shift>Space"),
                     new Gtk.NamedAction("focus-prev")));

        // Keyboard bindings for the "scroll" action signal
        string[] triggers = {
            "Up", "Down", "Page_Up", "Page_Down", "Home", "End"
        };
        Gtk.ScrollType[] types = {
            STEP_UP, STEP_DOWN, PAGE_UP, PAGE_DOWN, START, END
        };
        for (int i = 0; i < triggers.length; i++) {
            var shortcut = new Gtk.Shortcut(
                Gtk.ShortcutTrigger.parse_string(triggers[i]),
                new Gtk.SignalAction("scroll")
            );
            shortcut.set_arguments(new GLib.Variant("(i)", types[i]));
            add_shortcut(shortcut);
        }
    }

    private static int on_sort(Gtk.ListBoxRow row1, Gtk.ListBoxRow row2) {
        Convey.Email? email1 = ((ConversationRow) row1).email;
        Convey.Email? email2 = ((ConversationRow) row2).email;

        if (email1 == null) {
            return 1;
        }
        if (email2 == null) {
            return -1;
        }
        return Convey.Email.compare_sent_date_ascending(email1, email2);
    }

    internal Gtk.ListBox listbox { get; set; default = new Gtk.ListBox(); }


    /** Whether the latest email was sent via a mailing list. */
    public bool latest_has_list_post { get; private set; default = false; }

    /** Conversation being displayed. */
    public Convey.App.Conversation conversation { get; private set; }

    /** Search manager for highlighting search terms in this list. */
    public SearchManager search { get; private set; }

    /** Specifies if this list box currently has an embedded composer. */
    public bool has_composer {
        get { return this.current_composer != null; }
    }

    // Used to load messages in conversation.
    private Convey.App.EmailStore email_store;

    // Store from which to lookup contacts
    private Application.ContactStore contacts;

    // App config
    private Application.Configuration config;

    // Cancellable for this conversation's data loading.
    private Cancellable cancellable = new Cancellable();

    // Email view with selected text, if any
    private ConversationEmail? body_selected_view = null;

    // Maps displayed emails to their corresponding rows.
    private Gee.Map<Convey.EmailIdentifier,EmailRow> email_rows =
        new Gee.HashMap<Convey.EmailIdentifier,EmailRow>();

    private string? conversation_subject = null;

    // The current composer, if any
    private ComposerRow? current_composer = null;

    // Keeps the active scroll animation alive until it completes
    private Adw.Animation? scroll_animation = null;

    // The id of the draft referred to by the current composer.
    private Convey.EmailIdentifier? draft_id = null;

    private bool suppress_mark_timer;
    private Convey.TimeoutManager mark_read_timer;

    private GLib.SimpleActionGroup email_actions = new GLib.SimpleActionGroup();


    /** Keyboard action to scroll the conversation. */
    [Signal (action=true)]
    public virtual signal void scroll(Gtk.ScrollType type) {

        // If there is an embedded composer, check to see if one of
        // its non-web view widgets is focused and give the key press
        // to that instead. If not, then standard nav
        var handled = false;
        var composer = this.current_composer;
        if (composer != null) {
            var window = get_root() as Gtk.Window;
            if (window != null) {
                var focused = window.get_focus();
                if (focused != null &&
                    focused.is_ancestor(composer) &&
                    !(focused is Composer.WebView)) {
                    switch (type) {
                    case Gtk.ScrollType.STEP_UP:
                        composer.focus(UP);
                        handled = true;
                        break;
                    case Gtk.ScrollType.STEP_DOWN:
                        composer.focus(DOWN);
                        handled = true;
                        break;
                    default:
                        // no-op
                        break;
                    }
                }
            }
        }

        if (!handled) {
            Gtk.Adjustment adj = this.listbox.get_adjustment();
            double value = adj.get_value();
            switch (type) {
            case Gtk.ScrollType.STEP_UP:
                value -= adj.get_step_increment();
                break;
            case Gtk.ScrollType.STEP_DOWN:
                value += adj.get_step_increment();
                break;
            case Gtk.ScrollType.PAGE_UP:
                value -= adj.get_page_increment();
                break;
            case Gtk.ScrollType.PAGE_DOWN:
                value += adj.get_page_increment();
                break;
            case Gtk.ScrollType.START:
                value = 0.0;
                break;
            case Gtk.ScrollType.END:
                value = adj.get_upper();
                break;
            default:
                // no-op
                break;
            }
            adj.set_value(value);
            this.mark_read_timer.start();
        }
    }

    /** Keyboard action to shift focus to the next message, if any. */
    [Signal (action=true)]
    public virtual signal void focus_next() {
        this.listbox.move_cursor(Gtk.MovementStep.DISPLAY_LINES, 1, false, false);
        this.mark_read_timer.start();
    }

    /** Keyboard action to shift focus to the prev message, if any. */
    [Signal (action=true)]
    public virtual signal void focus_prev() {
        this.listbox.move_cursor(Gtk.MovementStep.DISPLAY_LINES, -1, false, false);
        this.mark_read_timer.start();
    }

    /** Fired when an email is fully loaded in the list box. */
    public signal void email_loaded(Convey.Email email);

    /** Fired when the user clicks "reply" in the message menu. */
    public signal void reply_to_sender_email(Convey.Email email, string? quote);

    /** Fired when the user clicks "reply all" in the message menu. */
    public signal void reply_to_all_email(Convey.Email email, string? quote);

    /** Fired when the user clicks "reply to list" in the message menu. */
    public signal void reply_to_list_email(Convey.Email email, string? quote);

    /** Fired when the user clicks "forward" in the message menu. */
    public signal void forward_email(Convey.Email email, string? quote);

    /** Fired when the user clicks "unsubscribe" in the message header. */
    public signal void unsubscribe_email(Convey.Email email);

    /** Emitted when email message flags are to be updated. */
    public signal void mark_email(Gee.Collection<Convey.EmailIdentifier> email,
                                  Convey.NamedFlag? to_add,
                                  Convey.NamedFlag? to_remove);

    /** Fired when the user clicks "trash" in the message menu. */
    public signal void trash_email(Convey.Email email);

    /** Fired when the user clicks "delete" in the message menu. */
    public signal void delete_email(Convey.Email email);


    /**
     * Constructs a new conversation list box instance.
     */
    public ConversationListBox(Convey.App.Conversation conversation,
                               bool suppress_mark_timer,
                               Convey.App.EmailStore email_store,
                               Application.ContactStore contacts,
                               Application.Configuration config,
                               Gtk.Adjustment adjustment) {
        base_ref();
        this.conversation = conversation;
        this.email_store = email_store;
        this.contacts = contacts;
        this.config = config;

        this.search = new SearchManager(this, conversation);

        this.suppress_mark_timer = suppress_mark_timer;
        this.mark_read_timer = new Convey.TimeoutManager.milliseconds(
            MARK_READ_TIMEOUT_MSEC, this.check_mark_read
        );

        this.child = this.listbox;
        this.listbox.selection_mode = NONE;
        this.listbox.valign = Gtk.Align.START;

        this.listbox.add_css_class("conversation-listbox");

        this.listbox.set_adjustment(adjustment);
        this.listbox.set_sort_func(ConversationListBox.on_sort);

        this.email_actions.add_action_entries(email_action_entries, this);
        insert_action_group(EMAIL_ACTION_GROUP_NAME, this.email_actions);

        this.listbox.row_activated.connect(on_row_activated);

        this.conversation.appended.connect(on_conversation_appended);
        this.conversation.trimmed.connect(on_conversation_trimmed);
        this.conversation.email_flags_changed.connect(on_update_flags);
    }

    ~ConversationListBox() {
        base_unref();
    }

    public override void dispose() {
        this.search.cancel();
        this.cancellable.cancel();
        this.email_rows.clear();
        this.mark_read_timer.reset();
        base.dispose();
    }

    public void append(Gtk.Widget child) {
      this.listbox.append(child);
      update_previous_sibling_css_class();
    }

    public new void remove(Gtk.Widget child) {
      this.listbox.remove(child);
      update_previous_sibling_css_class();
    }

    public new void insert(Gtk.Widget child, int position) {
      this.listbox.insert(child, position);
      update_previous_sibling_css_class();
    }

    // This is mostly taken form libhandy HdyExpanderRow
    private void update_previous_sibling_css_class() {
        unowned var child = get_first_child() as ConversationRow;
        if (child == null)
            return;

        unowned var next = child.get_next_sibling() as ConversationRow;
        while (next != null) {

            child = next;
            next = child.get_next_sibling() as ConversationRow;

            if (next.is_expanded) {
                child.add_css_class("convey-expanded-previous-sibling");
            } else {
                child.remove_css_class("convey-expanded-previous-sibling");
            }
        }
    }

    public async void load_conversation(Gee.Collection<Convey.EmailIdentifier> scroll_to,
                                        Convey.SearchQuery? query)
        throws GLib.Error {
        this.check_latest_list_post.begin();
        this.listbox.set_sort_func(null);

        Gee.Collection<Convey.Email>? all_email = this.conversation.get_emails(
            Convey.App.Conversation.Ordering.SENT_DATE_ASCENDING
        );

        // Work out what the first interesting email is, and load it
        // before all of the email before and after that so we can
        // load them in an optimal order.
        Gee.LinkedList<Convey.Email> uninteresting =
            new Gee.LinkedList<Convey.Email>();
        Convey.Email? first_interesting = null;
        Gee.LinkedList<Convey.Email> post_interesting =
            new Gee.LinkedList<Convey.Email>();

        if (!scroll_to.is_empty) {
            var valid_scroll_to = Convey.traverse(scroll_to).filter(
                id => this.conversation.contains_email_by_id(id)
            ).to_array_list();
            valid_scroll_to.sort((a, b) => a.natural_sort_comparator(b));
            var first_scroll = Convey.Collection.first(valid_scroll_to);

            if (first_scroll != null) {
                foreach (Convey.Email email in all_email) {
                    if (first_interesting == null) {
                        if (email.id.equal_to(first_scroll)) {
                            first_interesting = email;
                        } else {
                            // Inserted reversed so most recent uninteresting
                            // rows are added first.
                            uninteresting.insert(0, email);
                        }
                    } else {
                        post_interesting.add(email);
                    }
                }
            }
        }

        if (first_interesting == null) {
            foreach (Convey.Email email in all_email) {
                if (first_interesting == null) {
                    if (is_interesting(email)) {
                        first_interesting = email;
                    } else {
                        // Inserted reversed so most recent uninteresting
                        // rows are added first.
                        uninteresting.insert(0, email);
                    }
                } else {
                    post_interesting.add(email);
                }
            }
        }

        if (first_interesting == null) {
            // No interesting messages found so use the last one.
            first_interesting = uninteresting.remove_at(0);
        }
        EmailRow interesting_row = add_email(first_interesting);

        // If we have at least one uninteresting and one
        // post-interesting to load afterwards, show a spinner above
        // the interesting row to act as a placeholder.
        if (!uninteresting.is_empty && !post_interesting.is_empty) {
            insert(new LoadingRow(), 0);
        }

        // Load the interesting row completely up front, and load the
        // remaining in the background so we can return fast.
        yield interesting_row.view.load_contacts();
        yield interesting_row.expand();
        this.finish_loading.begin(
            query, scroll_to.is_empty, uninteresting, post_interesting
        );
    }

    public void set_conversation_subject(string subject) {
        this.conversation_subject = subject;
        email_view_iterator().foreach((view) => {
                view.primary_message.set_conversation_subject(subject);
                return true;
            });
    }

    /** Cancels loading the current conversation, if still in progress */
    public void cancel_conversation_load() {
        this.cancellable.cancel();
    }

    /** Scrolls to the closest message in the current conversation. */
    public void scroll_to_messages(Gee.Collection<Convey.EmailIdentifier> targets) {
        // Get the currently displayed email, allowing for some
        // padding at the top
        Gtk.ListBoxRow? current_child = this.listbox.get_row_at_y(32);

        // Find the row currently at the top of the viewport
        EmailRow? current = null;
        if (current_child != null) {
            int pos = current_child.get_index();
            do {
                current = current_child as EmailRow;
                current_child = this.listbox.get_row_at_index(--pos);
            } while (current == null && pos > 0);
        }

        EmailRow? best = null;
        // Find the message closest to the current message, preferring
        // an earlier one. If there's no current message, the list is
        // empty and we don't have anything to scroll to anyway.
        if (current != null) {
            uint closest_distance = uint.MAX;
            foreach (var id in targets) {
                EmailRow? target = this.email_rows[id];
                if (target != null) {
                    uint distance = (
                        current.get_index() - target.get_index()
                    ).abs();
                    if (distance < closest_distance ||
                        (distance == closest_distance &&
                         Convey.Email.compare_sent_date_ascending(
                             target.email, best.email
                         ) < 0)) {
                        closest_distance = distance;
                        best = target;
                    }

                }
            }
        }

        if (best != null) {
            scroll_to_row(best);
            best.expand.begin();
        }
    }

    /**
     * Returns the email view to be replied to, if any.
     *
     * If an email view has a visible body and selected text, that
     * view will be returned. Else the last message by sort order will
     * be returned, if any.
     */
    public ConversationEmail? get_reply_target() {
        ConversationEmail? view = get_selection_view();
        if (view == null) {
            EmailRow? last = null;
            for (int i = 0; true; i++) {
                unowned var row = this.listbox.get_row_at_index(i) as EmailRow;
                if (row == null)
                    break;
                last = row;
            }

            if (last != null) {
                view = last.view;
            }
        }
        return view;
    }

    /**
     * Returns the email view with a visible user selection, if any.
     *
     * If an email view has selected body text.
     */
    public ConversationEmail? get_selection_view() {
        ConversationEmail? view = this.body_selected_view;
        if (view != null) {
            if (view.is_collapsed) {
                // A collapsed email can't be visible. Note this
                // doesn't check whether the selected text in an
                // expanded email is actually on screen.
                view = null;
            }
        }
        return view;
    }

    /**
     * Adds an an embedded composer to the view.
     */
    public void add_embedded_composer(Composer.Embed embed, bool is_draft) {
        if (is_draft) {
            this.draft_id = embed.referred.id;
            EmailRow? draft = this.email_rows.get(embed.referred.id);
            if (draft != null) {
                remove_email(draft.email);
            }
        }

        ComposerRow row = new ComposerRow(embed);
        row.enable_should_scroll();
        // Use row param rather than row var from closure to avoid a
        // circular ref.
        row.should_scroll.connect((row) => { scroll_to_row(row); });
        append(row);
        this.current_composer = row;

        embed.composer.notify["saved-id"].connect(
            (id) => { this.draft_id = embed.composer.saved_id; }
        );
        embed.vanished.connect(() => {
                this.current_composer = null;
                this.draft_id = null;
                remove(row);
                if (is_draft &&
                    row.email != null &&
                    !this.cancellable.is_cancelled()) {
                    load_full_email.begin(row.email.id);
                }
            });
    }

    /**
     * Marks all email with a visible body read.
     */
    public void mark_visible_read() {
        if (!this.suppress_mark_timer) {
            this.mark_read_timer.start();
        }
    }

    /**
     * Marks all email with a visible body read, now and once loaded.
     */
    public void mark_visible_read_on_activate() {
        this.suppress_mark_timer = false;
        this.mark_read_timer.start();
    }

    /** Adds an info bar to the given email, if any. */
    public void add_email_info_bar(Convey.EmailIdentifier id,
                                   Components.InfoBar info_bar) {
        var row = this.email_rows.get(id);
        if (row != null) {
            row.view.primary_message.info_bars.add(info_bar);
        }
    }

    /** Adds an info bar to the given email, if any. */
    public void remove_email_info_bar(Convey.EmailIdentifier id,
                                      Components.InfoBar info_bar) {
        var row = this.email_rows.get(id);
        if (row != null) {
            row.view.primary_message.info_bars.remove(info_bar);
        }
    }

    /**
     * Increases the magnification level used for displaying messages.
     */
    // The message the user is looking at: the primary message of the
    // topmost email currently in the viewport. Zoom acts on this one
    // view so it responds instantly, rather than reflowing the whole
    // thread.
    private ConversationMessage? viewport_message() {
        var adj = this.listbox.get_adjustment();
        double bottom = adj.value + adj.page_size;
        var row = this.listbox.get_row_at_y(
            (int) adj.value + EMAIL_TOP_OFFSET
        ) as EmailRow;
        while (row != null && !row.is_expanded) {
            var next = this.listbox.get_row_at_index(row.get_index() + 1);
            Graphene.Point point = {};
            if (next == null ||
                !next.compute_point(this.listbox, { 0, 0 }, out point) ||
                point.y >= bottom) {
                return null;
            }
            row = next as EmailRow;
        }
        return row != null ? row.view.primary_message : null;
    }

    public void zoom_in() {
        var msg_view = viewport_message();
        if (msg_view != null)
            msg_view.zoom_in();
    }

    /**
     * Decreases the magnification level used for displaying messages.
     */
    public void zoom_out() {
        var msg_view = viewport_message();
        if (msg_view != null)
            msg_view.zoom_out();
    }

    /**
     * Resets magnification level used for displaying messages to the default.
     */
    public void zoom_reset() {
        var msg_view = viewport_message();
        if (msg_view != null)
            msg_view.zoom_reset();
    }

    /**
     * Updates the displayed date for each conversation row.
     */
    public void update_display() {
        message_view_iterator().foreach((msg_view) => {
                msg_view.update_display();
                return true;
            });
    }

    /** Returns the email row for the given id, if any. */
    internal EmailRow? get_email_row_by_id(Convey.EmailIdentifier id) {
        return this.email_rows.get(id);
    }

    private async void finish_loading(Convey.SearchQuery? query,
                                      bool enable_query_scroll,
                                      Gee.LinkedList<Convey.Email> to_insert,
                                      Gee.LinkedList<Convey.Email> to_append)
        throws GLib.Error {
        // Add emails to append first because if the first interesting
        // message was short, these will show up in the UI under it,
        // filling the empty space.
        foreach (Convey.Email email in to_append) {
            EmailRow row = add_email(email);
            yield row.view.load_contacts();
            if (is_interesting(email)) {
                yield row.expand();
            }
            yield throttle_loading();
        }

        // Since first rows may have extra margin, remove that from
        // the height of rows when adjusting scrolling.
        Gtk.ListBoxRow initial_row = this.listbox.get_row_at_index(0);
        int loading_height = 0;
        if (initial_row is LoadingRow) {
            // get_border_box_height already excludes the CSS margin in
            // GTK4, and the conversation rows carry no top margin, so no
            // further margin adjustment is needed here.
            loading_height = Util.Gtk.get_border_box_height(initial_row);
            remove(initial_row);
        }

        // None of these will be interesting, so just add them all,
        // but keep the scrollbar adjusted so that the first
        // interesting message remains visible.
        Gtk.Adjustment listbox_adj = this.listbox.get_adjustment();
        int i_mail_loaded = 0;
        foreach (Convey.Email email in to_insert) {
            EmailRow row = add_email(email, false);
            // Since uninteresting rows are inserted above the
            // first expanded, adjust the scrollbar as they are
            // inserted so as to keep the list scrolled to the
            // same place.
            row.enable_should_scroll();
            row.should_scroll.connect(() => {
                    listbox_adj.value += (Util.Gtk.get_border_box_height(row) - loading_height);
                    // Only adjust for the loading row going away once
                    loading_height = 0;
                });

            yield row.view.load_contacts();
            if (i_mail_loaded % 10 == 0)
                yield throttle_loading();
            ++i_mail_loaded;
        }

        this.listbox.set_sort_func(on_sort);

        if (query != null) {
            // Note for large conversations it can take
            // a long time for the load to complete and hence for
            // matches to show up.
            yield this.search.highlight_matching_email(
                query, enable_query_scroll
            );
        }
    }

    private inline async void throttle_loading() throws GLib.IOError {
        // Give GTK a moment to process newly added rows, so when
        // updating the adjustment below the values are
        // valid. Priority must be low otherwise other async tasks
        // (like cancelling loading if another conversation is
        // selected) won't get a look in until this is done.
        GLib.Idle.add(
            this.throttle_loading.callback, GLib.Priority.LOW
        );
        yield;

        // Check for cancellation after resuming in case the load was
        // cancelled in the mean time.
        if (this.cancellable.is_cancelled()) {
            throw new GLib.IOError.CANCELLED(
                "Conversation load cancelled"
            );
        }
    }

    private Convey.Email? get_latest_email() {
        Convey.Email? latest = null;
        foreach (var email in this.conversation.get_emails(SENT_DATE_ASCENDING)) {
            latest = email;
        }
        return latest;
    }

    private async void check_latest_list_post() {
        Convey.Email? latest = get_latest_email();
        if (latest == null) {
            return;
        }
        try {
            latest = yield this.email_store.fetch_email_async(
                latest.id, HEADER, LOCAL_ONLY, this.cancellable
            );
        } catch (GLib.Error err) {
            return;
        }
        this.latest_has_list_post =
            Convey.RFC822.Utils.get_list_post_address(latest) != null;
        notify_property("latest-has-list-post");
    }

    private void on_row_email_loaded(Convey.Email loaded) {
        Convey.Email? latest = get_latest_email();
        if (latest != null && loaded.id.equal_to(latest.id)) {
            this.latest_has_list_post =
                Convey.RFC822.Utils.get_list_post_address(loaded) != null;
        }
        email_loaded(loaded);
    }

    // Loads full version of an email, adds it to the listbox
    private async void load_full_email(Convey.EmailIdentifier id)
        throws GLib.Error {
        // Even though it would save a around-trip, don't load the
        // full email here so that ConverationEmail can handle it if
        // the full email isn't actually available in the same way as
        // any other.
        Convey.Email full_email = yield this.email_store.fetch_email_async(
            id,
            REQUIRED_FIELDS | ConversationEmail.REQUIRED_FOR_CONSTRUCT,
            Convey.Folder.ListFlags.NONE,
            this.cancellable
        );

        // Re-check for an existing row: the fetch above yields, so a
        // second append signal for the same email can get this far too.
        if (!this.cancellable.is_cancelled() &&
            !this.email_rows.has_key(id)) {
            EmailRow row = add_email(full_email);
            yield row.view.load_contacts();
            if (is_interesting(full_email)) {
                yield row.expand();
            }
            this.search.highlight_row_if_matching(row);
        }
    }

    // Constructs a row and view for an email, adds it to the listbox
    private EmailRow add_email(Convey.Email email, bool append_row = true) {
        // The initial conversation load and the conversation's
        // "appended" signal can race to add the same email — e.g. when
        // opening a just-arrived message from a notification — and the
        // append handler's has_key() guard is checked before an async
        // load, so it does not prevent this. Return any existing row
        // rather than adding a duplicate.
        EmailRow? existing = this.email_rows.get(email.id);
        if (existing != null) {
            return existing;
        }

        bool is_sent = false;
        Convey.Account account = this.conversation.base_folder.account;
        if (email.from != null) {
            foreach (Convey.RFC822.MailboxAddress from in email.from) {
                if (account.information.has_sender_mailbox(from)) {
                    is_sent = true;
                    break;
                }
            }
        }

        ConversationEmail view = new ConversationEmail(
            conversation,
            email,
            this.email_store,
            this.contacts,
            this.config,
            is_sent,
            is_draft(email),
            this.cancellable
        );
        view.primary_message.set_conversation_subject(this.conversation_subject);
        view.internal_link_activated.connect(on_internal_link_activated);
        view.body_selection_changed.connect((email, has_selection) => {
                this.body_selected_view = has_selection ? email : null;
            });
        view.notify["message-body-state"].connect(
            on_message_body_state_notify
        );

        EmailRow row = new EmailRow(view);
        row.email_loaded.connect(on_row_email_loaded);
        this.email_rows.set(email.id, row);

        if (append_row) {
            append(row);
        } else {
            insert(row, 0);
        }

        return row;
    }

    // Removes the email's row from the listbox, if any
    private void remove_email(Convey.Email email) {
        EmailRow? row = null;
        if (this.email_rows.unset(email.id, out row)) {
            remove(row);
        }
    }

    private void scroll_to_row(ConversationRow row) {
        // GTK4 positions rows via transforms, so allocation
        // coordinates are not parent-relative; translate into the
        // listbox's (unscrolled, full-content) coordinate space.
        Graphene.Point point;
        if (!row.compute_point(this.listbox, { 0, 0 }, out point)) {
            return;
        }
        double y = 0;
        if (point.y > EMAIL_TOP_OFFSET) {
            y = point.y - EMAIL_TOP_OFFSET;
        }

        // Animate to the target so reaching the composer or a message
        // glides into place rather than snapping.
        this.scroll_animation = Util.Gtk.animate_adjustment(
            this.listbox, this.listbox.get_adjustment(), y
        );
    }

    private void scroll_to_anchor(EmailRow row, int anchor_y) {
        double x = 0, y = 0;
        row.view.primary_message.web_view_translate_coordinates(
            this.listbox, 0, anchor_y, out x, out y
        );
        this.listbox.get_adjustment().set_value(y);
    }

    /**
     * Finds any currently visible messages, marks them as being read.
     */
    private void check_mark_read() {
        Gee.List<Convey.EmailIdentifier> email_ids =
            new Gee.LinkedList<Convey.EmailIdentifier>();
        Gtk.Adjustment adj = this.listbox.get_adjustment();
        int top_bound = (int) adj.value;
        int bottom_bound = top_bound + (int) adj.page_size;

        for (int i = 0; true; i++) {
            unowned var row = this.listbox.get_row_at_index(i) as EmailRow;
            if (row == null)
                break;

            // Don't bother with not-yet-loaded emails since the
            // size of the body will be off, affecting the visibility
            // of emails further down the conversation.
            ConversationEmail? view = (row != null) ? row.view : null;
            Convey.Email? email = (view != null) ? view.email : null;
            if (row != null &&
                row.is_expanded &&
                view.message_body_state == COMPLETED &&
                !view.is_manually_read &&
                this.conversation.has_unread_copy(email.id)) {
                ConversationMessage conversation_message = view.primary_message;
                 double body_top = 0;
                 double body_left = 0;
                 conversation_message.web_view_translate_coordinates(
                     this,
                     0, 0,
                     out body_left, out body_top
                 );

                 int body_height = conversation_message.web_view_get_allocated_height();
                 int body_bottom = (int) body_top + body_height;

                 // Only mark the email as read if it's actually visible
                 if (body_height > 0 &&
                     body_bottom > top_bound &&
                     (int) body_top + MARK_READ_PADDING < bottom_bound) {
                     email_ids.add(view.email.id);

                     // Since it can take some time for the new flags
                     // to round-trip back to our signal handlers,
                     // mark as manually read here
                     view.is_manually_read = true;
                 }
             }
        }

        if (email_ids.size > 0) {
            mark_email(email_ids, null, Convey.EmailFlags.UNREAD);
        }
    }

    /**
     * Returns an new Iterable over all email views in the viewer
     */
    private Gee.Iterator<ConversationEmail> email_view_iterator() {
        return this.email_rows.values.map<ConversationEmail>((row) => {
                return ((EmailRow) row).view;
            });
    }

    /**
     * Returns a new Iterable over all message views in the viewer
     */
    private Gee.Iterator<ConversationMessage> message_view_iterator() {
        return Gee.Iterator.concat<ConversationMessage>(
            email_view_iterator().map<Gee.Iterator<ConversationMessage>>(
                (email_view) => { return email_view.iterator(); }
            )
        );
    }

    /** Determines if an email should be expanded by default. */
    private inline bool is_interesting(Convey.Email email) {
        return (
            email.is_unread().is_certain() ||
            email.is_flagged().is_certain() ||
            is_draft(email)
        );
    }

    /** Determines if an email should be considered to be a draft. */
    private inline bool is_draft(Convey.Email email) {
        // Only emails in the drafts folder itself are editable;
        // ideally this would be more like "is in drafts folder" so
        // drafts could be edited from any conversation
        Convey.Folder.SpecialUse use = this.conversation.base_folder.used_as;
        bool is_in_folder = this.conversation.is_in_base_folder(email.id);

        return (
            is_in_folder && use == DRAFTS // ||
            //email.flags.is_draft()
        );
    }

    private ConversationEmail action_target_to_view(GLib.Variant target) {
        Convey.EmailIdentifier? id = null;
        try {
            id = this.conversation.base_folder.account.to_email_identifier(target);
        } catch (Convey.EngineError err) {
            debug("Failed to get email id for action target: %s", err.message);
        }
        EmailRow? row = (id != null) ? this.email_rows[id] : null;
        return (row != null) ? row.view : null;
    }

    private void on_conversation_appended(Convey.App.Conversation conversation,
                                          Convey.Email email) {
        on_conversation_appended_async.begin(conversation, email);
    }

    private async void on_conversation_appended_async(
        Convey.App.Conversation conversation, Convey.Email part_email) {
        // Don't add rows that are already present, or that are
        // currently being edited.
        if (!this.email_rows.has_key(part_email.id) &&
            part_email.id != this.draft_id) {
            load_full_email.begin(part_email.id, (obj, ret) => {
                    try {
                        load_full_email.end(ret);
                    } catch (Error err) {
                        debug(
                            "Unable to append email to conversation: %s",
                            err.message
                        );
                    }
                });
        }
    }

    private void on_conversation_trimmed(Convey.Email email) {
        remove_email(email);
    }

    private void on_update_flags(Convey.Email email) {
        if (!this.email_rows.has_key(email.id)) {
            return;
        }

        EmailRow row = this.email_rows.get(email.id);
        row.view.update_flags(email);
    }

    private void on_message_body_state_notify(GLib.Object obj,
                                              GLib.ParamSpec param) {
        ConversationEmail? view = obj as ConversationEmail;
        if (view != null && view.message_body_state == COMPLETED) {
            if (!this.suppress_mark_timer) {
                this.mark_read_timer.start();
            }
            this.suppress_mark_timer = false;
        }
    }

    private void on_row_activated(Gtk.ListBoxRow widget) {
        EmailRow? row = widget as EmailRow;
        if (row != null) {
            // Allow non-last rows to be expanded/collapsed, but also let
            // the last row to be expanded since appended sent emails will
            // be appended last. Finally, don't let rows with active
            // composers be collapsed.
            if (row.is_expanded) {
                if (this.listbox.get_row_at_index(row.get_index() + 1) != null) {
                    row.collapse();
                }
            } else {
                row.expand.begin();
            }
        }
    }

    private void on_internal_link_activated(ConversationEmail email, int y) {
        EmailRow row = get_email_row_by_id(email.email.id);
        scroll_to_anchor(row, y);
    }

    // Email action callbacks

    private void on_email_reply_sender(GLib.SimpleAction action,
                                       GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.get_selection_for_quoting.begin((obj, res) => {
                    string? quote = view.get_selection_for_quoting.end(res);
                    reply_to_sender_email(view.email, quote);
                });
        }
    }

    private void on_email_reply_all(GLib.SimpleAction action,
                                    GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.get_selection_for_quoting.begin((obj, res) => {
                    string? quote = view.get_selection_for_quoting.end(res);
                    reply_to_all_email(view.email, quote);
                });
        }
    }

    private void on_email_reply_list(GLib.SimpleAction action,
                                     GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.get_selection_for_quoting.begin((obj, res) => {
                    string? quote = view.get_selection_for_quoting.end(res);
                    reply_to_list_email(view.email, quote);
                });
        }
    }

    private void on_email_unsubscribe(GLib.SimpleAction action,
                                      GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            unsubscribe_email(view.email);
        }
    }

    private void on_email_forward(GLib.SimpleAction action,
                                  GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.get_selection_for_quoting.begin((obj, res) => {
                    string? quote = view.get_selection_for_quoting.end(res);
                    forward_email(view.email, quote);
                });
        }
    }

    private void on_email_mark_read(GLib.SimpleAction action,
                                    GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            mark_email(
                Convey.Collection.single(view.email.id),
                null,
                Convey.EmailFlags.UNREAD
            );
        }
    }

    private void on_email_mark_unread(GLib.SimpleAction action,
                                      GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            mark_email(
                Convey.Collection.single(view.email.id),
                Convey.EmailFlags.UNREAD,
                null
            );
        }
    }

    private void on_email_mark_unread_down(GLib.SimpleAction action,
                                           GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            Convey.Email email = view.email;
            var ids = new Gee.LinkedList<Convey.EmailIdentifier>();
            ids.add(email.id);
            for (int i = 0; true; i++) {
                unowned var row = this.listbox.get_row_at_index(i) as EmailRow;
                if (row == null)
                    break;

                if (row.visible) {
                    Convey.Email other = row.view.email;
                    if (Convey.Email.compare_sent_date_ascending(
                            email, other) < 0) {
                        ids.add(other.id);
                    }
                }
            }
            mark_email(ids, Convey.EmailFlags.UNREAD, null);
        }
    }

    private void on_email_mark_starred(GLib.SimpleAction action,
                                       GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            mark_email(
                Convey.Collection.single(view.email.id),
                Convey.EmailFlags.FLAGGED,
                null
            );
        }
    }

    private void on_email_mark_unstarred(GLib.SimpleAction action,
                                         GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            mark_email(
                Convey.Collection.single(view.email.id),
                null,
                Convey.EmailFlags.FLAGGED
            );
        }
    }

    private void on_email_load_remote(GLib.SimpleAction action,
                                      GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            mark_email(
                Convey.Collection.single(view.email.id),
                Convey.EmailFlags.LOAD_REMOTE_IMAGES,
                null
            );
        }
    }

    private void on_email_trash(GLib.SimpleAction action,
                                GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            trash_email(view.email);
        }
    }

    private void on_email_delete(GLib.SimpleAction action,
                                 GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            delete_email(view.email);
        }
    }

    private void on_email_save_all_attachments(GLib.SimpleAction action,
                                               GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null && view.attachments_pane != null) {
            view.attachments_pane.save_all();
        }
    }

    private void on_email_print(GLib.SimpleAction action,
                                GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.print.begin();
        }
    }

    private void on_email_open_in_window(GLib.SimpleAction action,
                                         GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.primary_message.open_in_window();
        }
    }

    private void on_email_view_source(GLib.SimpleAction action,
                                      GLib.Variant? param) {
        ConversationEmail? view = action_target_to_view(param);
        if (view != null) {
            view.view_source.begin();
        }
    }

}
