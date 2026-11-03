/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2016,2019 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Displays the messages in a conversation and in-window composers.
 */
[GtkTemplate (ui = "/net/donnybeelo/Convey/conversation-viewer.ui")]
public class ConversationViewer : Adw.Bin, Convey.BaseInterface {

    /**
     * The current conversation listbox, if any.
     */
    public ConversationListBox? current_list {
        get; private set; default = null;
    }

    /** Returns the currently displayed composer if any. */
    public Composer.Widget? current_composer {
        get; private set; default = null;
    }

    /**
     * The most recent web view created in this viewer.
     *
     * Keep the last created web view around so others can share the
     * same WebKitGTK WebProcess.
     */
    internal ConversationWebView? previous_web_view { get; set; default = null; }

    private Application.Configuration config;
    private Application.DecryptedSubjects decrypted_subjects;

    private Gee.Set<Convey.App.Conversation>? selection_while_composing = null;
    private Gtk.Widget? page_before_composing = null;
    private GLib.Cancellable? find_cancellable = null;

    [GtkChild] public unowned Components.ConversationHeaderBar headerbar;

    [GtkChild] private unowned Gtk.Stack stack;

    // Stack pages
    [GtkChild] private unowned Adw.Spinner loading_page;
    [GtkChild] private unowned Adw.StatusPage no_conversations_page;
    [GtkChild] private unowned Gtk.Box conversation_page;
    [GtkChild] private unowned Adw.StatusPage multiple_conversations_page;
    [GtkChild] private unowned Adw.StatusPage empty_folder_page;
    [GtkChild] private unowned Adw.StatusPage empty_search_page;
    [GtkChild] private unowned Adw.Bin composer_page;

    [GtkChild] private unowned Gtk.Label conversation_subject;

    [GtkChild] public unowned Gtk.ScrolledWindow conversation_scroller;

    [GtkChild] internal unowned Gtk.SearchBar conversation_find_bar;

    [GtkChild] internal unowned Gtk.SearchEntry conversation_find_entry;
    private Components.EntryUndo conversation_find_undo;

    [GtkChild] private unowned Gtk.Button conversation_find_next;

    [GtkChild] private unowned Gtk.Button conversation_find_prev;


    /* Emitted when a new conversation list was added to this view. */
    public signal void conversation_added(ConversationListBox list);

    /* Emitted when a new conversation list was removed from this view. */
    public signal void conversation_removed(ConversationListBox list);


    /** The empty folder or search message being shown, if any. */
    public Adw.StatusPage? empty_page { get; private set; default = null; }

    static construct {
        set_css_name("convey-conversation-viewer");
    }

    /**
     * Constructs a new conversation view instance.
     */
    public ConversationViewer(Application.Configuration config,
                              Application.DecryptedSubjects decrypted_subjects) {
        base_ref();
        this.config = config;
        this.decrypted_subjects = decrypted_subjects;

        this.conversation_find_undo = new Components.EntryUndo(
            this.conversation_find_entry
        );

        this.conversation_find_bar.connect_entry(this.conversation_find_entry);

        this.conversation_scroller.vadjustment.value_changed.connect(() => {
            if (this.current_list != null) {
                this.current_list.mark_visible_read();
            }
        });
    }

    ~ConversationViewer() {
        base_unref();
    }

    /**
     * Puts the view into composer mode, showing a full-height composer.
     */
    public void do_compose(Composer.Widget composer) {
        var main_window = get_root() as Application.MainWindow;
        if (main_window != null) {
            Composer.Box box = new Composer.Box(
                composer, this.headerbar
            );
            this.current_composer = composer;

            ConversationList.View conversation_list = main_window.conversation_list_view;
            this.selection_while_composing = conversation_list.selected;
            conversation_list.unselect_all();

            box.vanished.connect(on_composer_closed);
            this.composer_page.child = box;
            this.page_before_composing = get_visible_child();
            set_visible_child(this.composer_page);
            composer.update_window_title();
        }
    }

    /**
     * Puts the view into composer mode, showing an embedded composer.
     */
    public void do_compose_embedded(Composer.Widget composer,
                                    Convey.Email? referred) {
        this.current_composer = composer;
        Composer.Embed embed = new Composer.Embed(
            referred,
            composer
        );
        embed.vanished.connect(on_composer_closed);

        // We need to temporarily disable kinetic scrolling so that if
        // it still has some momentum when the composer is inserted
        // and scrolled to, it won't jump away again. See Bug 778027.
        var kinetic = this.conversation_scroller.kinetic_scrolling;
        if (kinetic) this.conversation_scroller.kinetic_scrolling = false;

        if (this.current_list != null) {
            this.current_list.add_embedded_composer(
                embed,
                composer.saved_id != null
            );
            composer.update_window_title();
        }

        if (kinetic) this.conversation_scroller.kinetic_scrolling = true;

        // Set a minimal composer height
        composer.set_size_request(
            -1, this.conversation_scroller.get_height() / 3 * 2
        );
    }

    /**
     * Shows the loading UI.
     */
    public void show_loading() {
        set_visible_child(this.loading_page);
    }

    /**
     * Shows the UI when no conversations have been selected
     */
    public void show_none_selected() {
        set_visible_child(this.no_conversations_page);
    }

    /**
     * Shows the UI when multiple conversations have been selected
     */
    public void show_multiple_selected() {
        set_visible_child(this.multiple_conversations_page);
    }

    /**
     * Shows the empty folder UI.
     */
    public void show_empty_folder() {
        set_visible_child(this.empty_folder_page);
    }

   /**
     * Shows the empty search UI.
     */
    public void show_empty_search() {
        set_visible_child(this.empty_search_page);
    }

    /** Shows and focuses the find entry. */
    public void enable_find() {
        this.conversation_find_bar.set_search_mode(true);
        this.conversation_find_entry.grab_focus();
    }

    /**
     * Shows a conversation in the viewer.
     */
    public async void load_conversation(Convey.App.Conversation conversation,
                                        Gee.Collection<Convey.EmailIdentifier> scroll_to,
                                        Convey.App.EmailStore store,
                                        Application.ContactStore contacts,
                                        bool start_mark_timer)
        throws GLib.Error {
        var old_viewport = remove_current_list();

        ConversationListBox new_list = new ConversationListBox(
            conversation,
            !start_mark_timer,
            store,
            contacts,
            this.config,
            this.conversation_scroller.get_vadjustment()
        );

        // Need to fire this signal early so the the controller
        // can hook in to its signals to catch any emails added
        // during loading.
        this.conversation_added(new_list);

        // Also set up find infrastructure early so matching emails
        // are expanded and highlighted as they are added.
        this.conversation_find_next.set_sensitive(false);
        this.conversation_find_prev.set_sensitive(false);
        new_list.search.matches_updated.connect((count) => {
                bool found = count > 0;
                // Gtk.SearchEntry no longer has an icon API, so
                // indicate no-match with the error style instead
                if (found ||
                    Convey.String.is_empty(this.conversation_find_entry.text)) {
                    this.conversation_find_entry.remove_css_class("error");
                } else {
                    this.conversation_find_entry.add_css_class("error");
                }
                this.conversation_find_next.sensitive = found;
                this.conversation_find_prev.sensitive = found;
            });
        add_new_list(new_list);
        update_subject();
        set_visible_child(this.conversation_page);

        // Highlight matching terms from find if active, otherwise
        // from the search folder if that's where we are at
        var query = get_find_search_query(conversation.base_folder.account);
        if (query == null) {
            var search_folder = conversation.base_folder as Convey.App.SearchFolder;
            if (search_folder != null) {
                query = search_folder.query;
            }
        }

        yield new_list.load_conversation(scroll_to, query);
        old_viewport = null;
    }

    public void update_subject() {
        Convey.Email? email = this.current_list?.conversation.get_latest_recv_email(
            Convey.App.Conversation.Location.IN_FOLDER_OUT_OF_FOLDER
        );
        this.conversation_subject.visible = email != null;
        if (email != null) {
            this.conversation_subject.label =
                this.decrypted_subjects.get_display_subject(email);
            this.current_list.set_conversation_subject(
                this.conversation_subject.label
            );
        }
    }

    // Add a new conversation list to the UI
    private void add_new_list(ConversationListBox list) {
        this.current_list = list;
        list.show();

        // Manually create a Viewport rather than letting
        // ScrolledWindow do it so Container.set_focus_{h,v}adjustment
        // are not set on the list - it makes changing focus jumpy
        // when a row or its web_view are larger than the viewport.
        Gtk.Viewport viewport = new Gtk.Viewport(null, null);
        // Keep clicks that focus a message taller than the viewport
        // from scrolling the view (GTK4 equivalent of the focus
        // adjustment problem described above)
        viewport.scroll_to_focus = false;
        viewport.child = list;

        this.conversation_scroller.child = viewport;
    }

    // Remove any existing conversation list, cancelling its loading
    private Gtk.Widget remove_current_list() {
        // Remove the viewport that contains the current list
        Gtk.Widget? scrolled_child = this.conversation_scroller.get_child();
        if (scrolled_child != null) {
            this.conversation_scroller.child = null;
        }

        // Reset the scrollbars to their initial positions
        this.conversation_scroller.hadjustment.set_value(0);
        this.conversation_scroller.vadjustment.set_value(0);

        if (this.current_list != null) {
            this.current_list.cancel_conversation_load();
            this.conversation_removed(this.current_list);
            this.current_list = null;
        }
        return scrolled_child;
    }

    public Gtk.Widget get_visible_child() {
        return this.stack.visible_child;
    }

    /**
     * Sets the currently visible page of the stack.
     */
    private void set_visible_child(Gtk.Widget widget) {
        debug("Showing: %s", widget.get_name());
        Gtk.Widget current = get_visible_child();
        if (current == this.conversation_page) {
            if (widget != this.conversation_page) {
                // By removing the current list, any load it is currently
                // performing is also cancelled, which is important to
                // avoid a possible crit warning when switching folders,
                // etc.
                remove_current_list();
            }
        }
        this.stack.set_visible_child(widget);
        this.empty_page = (
            widget == this.empty_folder_page || widget == this.empty_search_page
        ) ? (Adw.StatusPage) widget : null;
    }

    private async void update_find_results() {
        ConversationListBox? list = this.current_list;
        if (list != null) {
            if (this.find_cancellable != null) {
                this.find_cancellable.cancel();
            }
            GLib.Cancellable cancellable = new GLib.Cancellable();
            cancellable.cancelled.connect(() => {
                    list.search.cancel();
                });
            this.find_cancellable = cancellable;
            try {
                var query = get_find_search_query(
                    list.conversation.base_folder.account
                );
                if (query != null) {
                    yield list.search.highlight_matching_email(query, true);
                }
            } catch (GLib.Error err) {
                warning("Error updating find results: %s", err.message);
            }
        }
    }

    private Convey.SearchQuery? get_find_search_query(Convey.Account account)
        throws GLib.Error {
        Convey.SearchQuery? query = null;
        if (this.conversation_find_bar.get_search_mode()) {
            string text = this.conversation_find_entry.get_text().strip();
            // Require find string of at least two chars to avoid
            // opening every message in the conversation as soon as
            // the user presses a key
            if (text.length >= 2) {
                var expr_factory = new Util.Email.SearchExpressionFactory(
                    this.config.get_search_strategy(),
                    account.information
                );
                query = account.new_search_query(
                    expr_factory.parse_query(text),
                    text
                );
            }
        }
        return query;
    }

    [GtkCallback]
    private void on_find_mode_changed(Object obj, ParamSpec param) {
        if (this.current_list != null) {
            if (this.conversation_find_bar.get_search_mode()) {
                // Find became enabled
                ConversationEmail? email_view =
                    this.current_list.get_selection_view();
                if (email_view != null) {
                    email_view.get_selection_for_find.begin((obj, res) => {
                            string text = email_view.get_selection_for_find.end(res);
                            if (text != null) {
                                this.conversation_find_entry.set_text(text);
                                this.conversation_find_entry.select_region(0, -1);
                            }
                        });
                }
            } else {
                // Find became disabled, re-show search terms if any
                this.current_list.search.unmark_terms();
                Convey.App.SearchFolder? search_folder = (
                    this.current_list.conversation.base_folder
                    as Convey.App.SearchFolder
                );
                this.conversation_find_undo.reset();
                if (search_folder != null) {
                    Convey.SearchQuery? query = search_folder.query;
                    if (query != null) {
                        this.current_list.search.highlight_matching_email.begin(
                            query,
                            true
                        );
                    }
                }
            }
        }
    }

    [GtkCallback]
    private void on_find_text_changed(Gtk.SearchEntry entry) {
        this.conversation_find_next.set_sensitive(false);
        this.conversation_find_prev.set_sensitive(false);
        this.update_find_results.begin();
    }

    [GtkCallback]
    private void on_find_next(Gtk.Widget entry) {
         if (this.current_list != null) {
             //this.current_list.show_prev_search_term();
         }
    }

    [GtkCallback]
    private void on_find_prev(Gtk.Widget entry) {
        if (this.current_list != null) {
            //this.current_list.show_next_search_term();
        }
    }

    private void on_composer_closed() {
        this.current_composer = null;
        if (get_visible_child() == this.composer_page) {
            set_visible_child(this.page_before_composing ?? this.conversation_page);

            // Restore the old selection
            var main_window = get_root() as Application.MainWindow;
            if (main_window != null) {
                main_window.update_title();

                if (this.selection_while_composing != null) {
                    var conversation_list = main_window.conversation_list_view;
                    if (this.selection_while_composing.is_empty) {
                        conversation_list.conversations_selected(
                            this.selection_while_composing
                        );
                        conversation_list.autoselect();
                    } else {
                        conversation_list.select_conversations(
                            this.selection_while_composing
                        );
                    }

                    this.selection_while_composing = null;
                }
            }
        }
    }
}
