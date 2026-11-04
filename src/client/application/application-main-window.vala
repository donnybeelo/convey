/*
 * Copyright © 2016 Software Freedom Conservancy Inc.
 * Copyright © 2016, 2019-2021 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

[GtkTemplate (ui = "/net/donnybeelo/Convey/application-main-window.ui")]
public class Application.MainWindow :
    Adw.ApplicationWindow, Convey.BaseInterface {


    // Named actions.
    public const string ACTION_ARCHIVE_CONVERSATION = "archive-conversation";
    public const string ACTION_CONVERSATION_DOWN = "down-conversation";
    public const string ACTION_CONVERSATION_UP = "up-conversation";
    public const string ACTION_DELETE_CONVERSATION = "delete-conversation";
    public const string ACTION_FIND_IN_CONVERSATION = "find-in-conversation";
    public const string ACTION_FORWARD_CONVERSATION = "forward-conversation";
    public const string ACTION_MARK_AS_READ = "mark-conversation-read";
    public const string ACTION_MARK_AS_STARRED = "mark-conversation-starred";
    public const string ACTION_MARK_AS_UNREAD = "mark-conversation-unread";
    public const string ACTION_MARK_AS_UNSTARRED = "mark-conversation-unstarred";
    public const string ACTION_REPLY_ALL_CONVERSATION = "reply-all-conversation";
    public const string ACTION_REPLY_LIST_CONVERSATION = "reply-list-conversation";
    public const string ACTION_REPLY_CONVERSATION = "reply-conversation";
    public const string ACTION_SEARCH = "search";
    public const string ACTION_SELECT_INBOX = "select-inbox";
    public const string ACTION_FOLDER_NEW = "folder-new";
    public const string ACTION_FOLDER_NEW_CHILD = "folder-new-child";
    public const string ACTION_FOLDER_RENAME = "folder-rename";
    public const string ACTION_FOLDER_DELETE = "folder-delete";
    public const string ACTION_SHOW_COPY_MENU = "show-copy-menu";
    public const string ACTION_TOGGLE_JUNK = "toggle-conversation-junk";
    public const string ACTION_TRASH_CONVERSATION = "trash-conversation";
    public const string ACTION_TRASH_OR_ARCHIVE_CONVERSATION = "trash-or-archive-conversation";
    public const string ACTION_ZOOM = "zoom";
    public const string ACTION_NAVIGATION_BACK = "navigation-back";

    private const ActionEntry[] EDIT_ACTIONS = {
        { Action.Edit.UNDO, on_undo },
        { Action.Edit.REDO, on_redo },
    };

    private const ActionEntry[] WINDOW_ACTIONS = {
        { Action.Window.CLOSE, on_close },
        { Action.Window.SHOW_HELP_OVERLAY, on_show_help_overlay },
        { Action.Window.SHOW_MENU, on_show_window_menu },

        { ACTION_FIND_IN_CONVERSATION, on_find_in_conversation_action },
        { ACTION_SEARCH, on_search_activated },
        { ACTION_SELECT_INBOX, on_select_inbox, "i" },

        // Folder actions
        { ACTION_FOLDER_NEW, on_folder_new },
        { ACTION_FOLDER_NEW_CHILD, on_folder_new_child },
        { ACTION_FOLDER_RENAME, on_folder_rename },
        { ACTION_FOLDER_DELETE, on_folder_delete },

        // Message actions
        { ACTION_REPLY_CONVERSATION, on_reply_conversation },
        { ACTION_REPLY_ALL_CONVERSATION, on_reply_all_conversation },
        { ACTION_REPLY_LIST_CONVERSATION, on_reply_list_conversation },
        { ACTION_FORWARD_CONVERSATION, on_forward_conversation },
        { ACTION_ARCHIVE_CONVERSATION, on_archive_conversation },
        { ACTION_TRASH_CONVERSATION, on_trash_conversation },
        { ACTION_TRASH_OR_ARCHIVE_CONVERSATION, on_trash_or_archive_conversation },
        { ACTION_DELETE_CONVERSATION, on_delete_conversation },
        { ACTION_SHOW_COPY_MENU, on_show_copy_menu },
        { ACTION_CONVERSATION_UP, on_conversation_up },
        { ACTION_CONVERSATION_DOWN, on_conversation_down },
        // Message marking actions
        { ACTION_MARK_AS_READ, on_mark_as_read },
        { ACTION_MARK_AS_UNREAD, on_mark_as_unread },
        { ACTION_MARK_AS_STARRED, on_mark_as_starred },
        { ACTION_MARK_AS_UNSTARRED, on_mark_as_unstarred },
        { ACTION_TOGGLE_JUNK, on_mark_as_junk_toggle },
        // Message viewer
        { ACTION_ZOOM, on_zoom, "s" },
    };

    private const int UPDATE_UI_INTERVAL = 60;
    private const int MAX_COMMAND_HISTORY = 100;

    private const int MIN_CONVERSATION_COUNT = 50;

    private const int ALL_INBOXES_WAIT = 5;

    public static void add_accelerators(Client owner) {
        for (int i = 1; i <= 9; i++) {
            owner.add_window_accelerators(
                ACTION_SELECT_INBOX+("(%d)".printf(i - 1)), { "<ALT>%d".printf(i) }
            );
        }

        // Zoom
        owner.add_window_accelerators(
            ACTION_ZOOM+("('in')"), { "<Ctrl>equal", "<Ctrl>plus" }
        );
        owner.add_window_accelerators(
            ACTION_ZOOM+("('out')"), { "<Ctrl>minus" }
        );
        owner.add_window_accelerators(
            ACTION_ZOOM+("('normal')"), { "<Ctrl>0" }
        );
    }


    private enum ConversationCount {
        NONE, SINGLE, MULTIPLE;

        public static ConversationCount for_size(int size) {
            return (
                size == 0
                ? NONE
                : size == 1
                ? SINGLE
                : MULTIPLE
            );
        }
    }


    /** Returns the window's associated client application instance. */
    public new Client application {
        get { return (Client) base.get_application(); }
        set { base.set_application(value); }
    }

    /** Currently selected account, null if none selected */
    public Convey.Account? selected_account { get; private set; default = null; }

    /** Currently selected folder, null if none selected */
    public Convey.Folder? selected_folder { get; private set; default = null; }

    /** Conversations for the current folder, null if none selected */
    public Convey.App.ConversationMonitor? conversations {
        get; private set; default = null;
    }

    // Set until the inbox remembered from last session has been
    // opened, or the user has picked a different one
    private bool restoring_last_inbox = true;

    // Delays falling back to the first inbox while All Inboxes loads
    private Convey.TimeoutManager all_inboxes_wait;
    private bool all_inboxes_wait_over = false;

    /** Whether the combined view of every account's inbox is selected. */
    public bool all_inboxes { get; private set; default = false; }

    // One per account inbox while the combined view is selected
    private Gee.List<Convey.App.ConversationMonitor> inbox_monitors =
        new Gee.ArrayList<Convey.App.ConversationMonitor>();

    /** Specifies if the conversation list is currently displayed. */
    public bool is_folder_list_shown {
        get {
            return (
                (!this.outer_view.collapsed || !this.outer_view.show_content)
                &&
                (!this.inner_view.collapsed || this.inner_view.show_sidebar)
            );
        }
    }

    /** Specifies if the conversation list is currently displayed. */
    public bool is_conversation_list_shown {
        get {
            return (
                (!this.outer_view.collapsed || !this.outer_view.show_content)
                &&
                (!this.inner_view.collapsed || !this.inner_view.show_sidebar)
            );
        }
    }

    /** Specifies if the conversation viewer is currently displayed. */
    public bool is_conversation_viewer_shown {
        get {
            return (
                !this.outer_view.collapsed || this.outer_view.show_content
            );
        }
    }

    /** The attachment manager for this window. */
    public AttachmentManager attachments { get; private set; }

    /** Determines if conversations in the selected folder can be trashed. */
    public bool selected_folder_supports_trash {
        get {
            return Controller.does_folder_support_trash(
                this.folder_for_actions
            );
        }
    }

    /**
     * The folders whose conversations the window is currently showing.
     *
     * A single folder when one is selected, every account's inbox when
     * the combined view is, and nothing otherwise.
     */
    private Gee.Collection<Convey.Folder> selected_folders {
        owned get {
            if (this.selected_folder != null) {
                return Convey.Collection.single<Convey.Folder>(
                    this.selected_folder
                );
            }
            return this.all_inboxes
                ? this.folder_list.get_all_inboxes()
                : Gee.Collection.empty<Convey.Folder>();
        }
    }

    /**
     * The folder deciding which conversation actions are available.
     *
     * The combined inbox view has no folder of its own, so one of the
     * inboxes stands in for what all of them support.
     */
    private Convey.Folder? folder_for_actions {
        owned get {
            if (this.selected_folder == null && this.all_inboxes) {
                var folders = selected_groups().get_keys();
                if (folders.size == 1) {
                    return Convey.Collection.first<Convey.Folder>(folders);
                }
            }
            return Convey.Collection.first<Convey.Folder>(
                this.selected_folders
            );
        }
    }

    /** Determines if a composer is currently open in this window. */
    public bool has_composer {
        get {
            return (this.conversation_viewer.current_composer != null);
        }
    }

    internal bool composer_open {
        get {
            var composer = this.conversation_viewer.current_composer;
            return composer != null &&
                composer.current_mode != NONE &&
                composer.current_mode != CLOSED;
        }
    }

    /** Specifies if the Shift key is currently being held. */
    public bool is_shift_down { get; private set; default = false; }

    // Used to save/load the window state between sessions.
    public int window_width { get; set; }
    public int window_height { get; set; }

    // Widget descendants
    public FolderList.Tree folder_list { get; private set; default = new FolderList.Tree(); }
    public SearchBar search_bar { get; private set; }

    public ConversationList.View conversation_list_view  { get; private set; }
    public ConversationViewer conversation_viewer { get; private set; }

    public Components.InfoBarStack conversation_list_info_bars {
        get; private set; default = new Components.InfoBarStack(PRIORITY_QUEUE);
    }

    private Controller controller;

    private Gee.Set<AccountContext> accounts = new Gee.HashSet<AccountContext>();

    private GLib.SimpleActionGroup edit_actions = new GLib.SimpleActionGroup();

    // Determines if the conversation viewer should auto-mark messages
    // on next load
    private bool previous_selection_was_interactive = false;

    // Caches the last non-search folder so it can be re-selected on
    // the search folder closing
    private Convey.Folder? previous_non_search_folder = null;

    private bool searching_all_inboxes = false;

    private Convey.AggregateProgressMonitor progress_monitor = new Convey.AggregateProgressMonitor();

    private GLib.Cancellable action_update_cancellable = new GLib.Cancellable();
    private GLib.Cancellable folder_open = new GLib.Cancellable();

    private Convey.TimeoutManager update_ui_timeout;
    private int64 update_ui_last = 0;

    [GtkChild] private unowned Gtk.ToggleButton search_button;
    [GtkChild] private unowned Gtk.ToggleButton conversation_list_selection_button;
    [GtkChild] private unowned Gtk.MenuButton app_menu_button;
    [GtkChild] private unowned Gtk.Button refresh_button;
    [GtkChild] private unowned Gtk.Stack refresh_stack;
    [GtkChild] private unowned Gtk.Image refresh_image;
    [GtkChild] private unowned Adw.Spinner headerbar_spinner;

    private int headerbar_busy_count = 0;
    private Adw.Toast? offline_toast = null;
    private Gee.LinkedList<Command> command_history = new Gee.LinkedList<Command>();

    [GtkChild] private unowned Adw.HeaderBar conversation_list_headerbar;

    // Outer and inner split are [[ folder_box | conversation_list ] | conversation_viewer ]
    [GtkChild] private unowned Adw.NavigationSplitView outer_view;
    [GtkChild] private unowned Adw.OverlaySplitView inner_view;
    [GtkChild] private unowned Gtk.Overlay empty_overlay;
    [GtkChild] private unowned Adw.StatusPage empty_overlay_page;
    [GtkChild] private unowned Gtk.Widget sidebar_resize_handle;
    private double sidebar_drag_start_width;
    private int default_min_sidebar_width;
    private int default_max_sidebar_width;
    private double default_sidebar_width_fraction;
    private bool sidebar_dragged = false;
    [GtkChild] private unowned Gtk.Widget folder_resize_handle;
    private double folder_drag_start_width;
    private int default_folder_list_width;
    private bool folder_list_dragged = false;

    [GtkChild] private unowned Gtk.ScrolledWindow folder_list_scrolled;

    [GtkChild] private unowned Adw.NavigationPage conversation_list_page;
    [GtkChild] private unowned Adw.WindowTitle conversation_list_title;
    [GtkChild] private unowned Gtk.Box conversation_list_box;
    [GtkChild] private unowned Gtk.Revealer conversation_list_actions_revealer;
    [GtkChild] private unowned Components.ConversationActions conversation_list_actions;
    [GtkChild] private unowned Components.ConversationActions conversation_viewer_actions;

    [GtkChild] private unowned Adw.NavigationPage conversation_viewer_page;
    [GtkChild] private unowned Gtk.Box conversation_viewer_box;
    [GtkChild] private unowned Gtk.Revealer conversation_viewer_actions_revealer;

    [GtkChild] private unowned Adw.ToastOverlay overlay;

    [GtkChild] private unowned Components.InfoBarStack info_bars;

    private Components.ConversationActions[] folder_conversation_actions = {};

    private Components.InfoBar offline_infobar;
    private Components.InfoBar cert_problem_infobar;
    private Components.InfoBar auth_problem_infobar;
    private Components.ProblemReportInfoBar? service_problem_infobar = null;

    /** Fired when the user requests an account status be retried. */
    public signal void retry_service_problem(Convey.ClientService.Status problem);


    /** Keybinding signal for replying to sender for the current conversation. */
    [Signal (action=true)]
    public virtual signal void reply_conversation_sender() {
        activate_action(get_window_action(ACTION_REPLY_CONVERSATION));
    }

    /** Keybinding signal for replying to all for the current conversation. */
    [Signal (action=true)]
    public virtual signal void reply_conversation_all() {
        activate_action(get_window_action(ACTION_REPLY_ALL_CONVERSATION));
    }

    /** Keybinding signal for forwarding the current conversation. */
    [Signal (action=true)]
    public virtual signal void forward_conversation() {
        activate_action(get_window_action(ACTION_FORWARD_CONVERSATION));
    }

    /** Keybinding signal for marking the current selection read. */
    [Signal (action=true)]
    public virtual signal void mark_conversations_read(bool prefer_read) {
        activate_action(
            prefer_read
            ? get_window_action(ACTION_MARK_AS_READ)
            : get_window_action(ACTION_MARK_AS_UNREAD)
        );
    }

    /** Keybinding signal for marking the current selection starred. */
    [Signal (action=true)]
    public virtual signal void mark_conversations_starred(bool prefer_starred) {
        activate_action(
            prefer_starred
            ? get_window_action(ACTION_MARK_AS_STARRED)
            : get_window_action(ACTION_MARK_AS_UNSTARRED)
        );
    }

    /** Keybinding signal for showing the copy/label menu. */
    [Signal (action=true)]
    public virtual signal void show_copy_menu() {
        activate_action(get_window_action(ACTION_SHOW_COPY_MENU));
    }

    /** Keybinding signal for archiving the current selection. */
    [Signal (action=true)]
    public virtual signal void archive_conversations() {
        activate_action(get_window_action(ACTION_ARCHIVE_CONVERSATION));
    }

    /** Keybinding signal for junking the current selection. */
    [Signal (action=true)]
    public virtual signal void junk_conversations() {
        activate_action(get_window_action(ACTION_TOGGLE_JUNK));
    }

    /** Keybinding signal for trashing the current selection. */
    [Signal (action=true)]
    public virtual signal void trash_conversations() {
        // The Shift+BackSpace combo above doesn't seem to work
        // for delete, so double-check here.
        activate_action(
            !this.is_shift_down
            ? get_window_action(ACTION_TRASH_OR_ARCHIVE_CONVERSATION)
            : get_window_action(ACTION_DELETE_CONVERSATION)
        );
    }

    /** Keybinding signal for deleting the current selection. */
    [Signal (action=true)]
    public virtual signal void delete_conversations() {
        activate_action(get_window_action(ACTION_DELETE_CONVERSATION));
    }

    /** Keybinding signal for activating conversation search. */
    [Signal (action=true)]
    public virtual signal void search() {
        activate_action(get_window_action(ACTION_SEARCH));
    }

    /** Keybinding signal for activating in-conversation find. */
    [Signal (action=true)]
    public virtual signal void find() {
        activate_action(get_window_action(ACTION_FIND_IN_CONVERSATION));
    }

    /** Keybinding signal for selecting all elements in current view. */
    [Signal (action=true)]
    public virtual signal void select_all() {
        this.conversation_list_view.select_all();
    }

    /** Keybinding signal for shifting the keyboard focus. */
    [Signal (action=true)]
    public virtual signal void navigate(Gtk.ScrollType type) {
        switch (type) {
        case Gtk.ScrollType.STEP_UP:
            activate_action(get_window_action(ACTION_CONVERSATION_UP));
            break;
        case Gtk.ScrollType.STEP_DOWN:
            activate_action(get_window_action(ACTION_CONVERSATION_DOWN));
            break;
        default:
            error_bell();
            break;
        }
    }


    internal MainWindow(Client application) {
        Object(
            application: application,
            show_menubar: false
        );
        base_ref();

        // Keep a ref on the current controller so that even if the
        // application has been shut down, any async tasks that are
        // running (and presumably being cancelled) can still complete
        // without a warning.
        this.controller = application.controller;

        // Create a new group for the window so attachment file
        // choosers (save attachments & composer attach files) do not
        // block other main windows or composers.
        var group = new Gtk.WindowGroup();
        group.add_window(this);

        load_config(application.config);
        restore_saved_window_state();

        if (Config.PROFILE != Client.PROFILE_RELEASE) {
            add_css_class("devel");
        }

        // Edit actions
        this.edit_actions.add_action_entries(EDIT_ACTIONS, this);
        insert_action_group(Action.Edit.GROUP_NAME, this.edit_actions);

        // Window actions
        add_action_entries(MainWindow.WINDOW_ACTIONS, this);

        setup_layout(application.config);

        update_command_actions();
        update_conversation_actions(NONE);

        this.attachments = new AttachmentManager(this);

        this.update_ui_timeout = new Convey.TimeoutManager.seconds(
            UPDATE_UI_INTERVAL, on_update_ui_timeout
        );
        this.update_ui_timeout.repetition = FOREVER;

        this.all_inboxes_wait = new Convey.TimeoutManager.seconds(
            ALL_INBOXES_WAIT, on_all_inboxes_wait_over
        );

        // Add future and existing accounts to the main window
        this.controller.account_available.connect(
            on_account_available
        );
        this.controller.account_unavailable.connect(
            on_account_unavailable
        );
        foreach (AccountContext context in
                 this.controller.get_account_contexts()) {
            add_account(context);
        }

        this.offline_infobar = new Components.InfoBar(
            // Translators: An info bar status label
            _("Working offline"),
            // Translators: An info bar description label
            _("You will not be able to send or receive email until re-connected.")
        );
        this.offline_infobar.show_close_button = true;
        this.offline_infobar.response.connect(on_offline_infobar_response);

        this.auth_problem_infobar = new Components.InfoBar(
            // Translators: An info bar status label
            _("Login problem"),
            // Translators: An info bar description label
            _("An account has reported an incorrect login or password.")
        );
        // Translators: An info bar button label
        var auth_retry = new Gtk.Button.with_label(_("Login"));
        auth_retry.show();
        // Translators: An info bar button tool-tip
        auth_retry.tooltip_text = _(
            "Retry login, you will be prompted for your password"
        );
        auth_retry.clicked.connect(on_auth_problem_retry);
        this.auth_problem_infobar.get_action_area().append(auth_retry);

        this.cert_problem_infobar = new Components.InfoBar(
            // Translators: An info bar status label
            _("Security problem"),
            // Translators: An info bar description label
            _("An account has reported an untrusted server.")
        );
        // Translators: An info bar button label
        var cert_retry = new Gtk.Button.with_label(_("Check"));
        cert_retry.show();
        // Translators: An info bar button tool-tip
        cert_retry.tooltip_text = _(
            "Check the security details for the connection"
        );
        cert_retry.clicked.connect(on_cert_problem_retry);
        this.cert_problem_infobar.get_action_area().append(cert_retry);

        this.map.connect(() => {
            // The message list is where the keyboard is most useful; fall
            // back to the folder list if it has nothing to focus yet.
            if (!this.conversation_list_view.grab_focus())
                this.folder_list.grab_focus();
        });

        foreach (var actions in this.folder_conversation_actions) {
            actions.mark_message_button_toggled.connect(on_show_mark_menu);
        }
    }

    ~MainWindow() {
        base_unref();
    }

    /** Updates the window's title and headerbar titles. */
    public void update_title() {
        if (this.all_inboxes) {
            this.title = _("All Inboxes");
            this.conversation_list_page.title = _("All Inboxes");
            this.conversation_list_title.title = _("All Inboxes");
            this.conversation_list_title.subtitle = "";
            return;
        }

        AccountContext? account = get_selected_account_context();
        FolderContext? folder = (
            account != null && this.selected_folder != null
            ? account.get_folder(this.selected_folder)
            : null
        );
        string title = _("Convey");
        string? account_name = null;
        string? folder_name = null;
        if (account != null && folder != null) {
            account_name = account.account.information.display_name;
            folder_name = folder.display_name;
            /// Translators: Main window title, first string
            /// substitution being the currently selected folder name,
            /// the second being the selected account name.
            title = _("%s — %s").printf(folder_name, account_name);
        }
        this.title = title;
        this.conversation_list_page.title = account_name ?? "";
        this.conversation_list_title.title = account_name ?? "";
        // Only show the address when it isn't already the title
        string address = (
            account != null ? account.account.information.primary_mailbox.address : ""
        );
        this.conversation_list_title.subtitle = (
            account_name != null && account_name != address ? address : ""
        );
    }

    /** Updates the window's account status info bars. */
    public void update_account_status(Convey.Account.Status status,
                                      bool has_auth_error,
                                      bool has_cert_error,
                                      Convey.Account? problem_source) {
        // Only ever show one info bar at a time. Offline is primary
        // since nothing else can happen when offline. Service
        // problems are secondary since auth and cert problems can't
        // be resolved when the service isn't talking to the
        // server. Cert problems are tertiary since you can't auth if
        // you can't connect.
        if (!status.is_online()) {
            this.info_bars.add(this.offline_infobar);
        } else if (status.has_service_problem()) {
            Convey.ClientService? service = (
                problem_source.incoming.last_error != null
                ? problem_source.incoming
                : problem_source.outgoing
            );
            this.service_problem_infobar = new Components.ProblemReportInfoBar(
                new Convey.ServiceProblemReport(
                    problem_source.information,
                    service.configuration,
                    service.last_error.thrown
                )
            );
            this.service_problem_infobar.retry.connect(on_service_problem_retry);
            this.info_bars.add(this.service_problem_infobar);
        } else if (has_cert_error) {
            this.info_bars.add(this.cert_problem_infobar);
        } else if (has_auth_error) {
            this.info_bars.add(this.auth_problem_infobar);
        } else {
            this.info_bars.remove_all();
        }
    }

    /**
     * Selects and open the given folder.
     *
     * If is_interactive is true, the selection is treated as being
     * caused directly by human request (e.g. clicking on a folder in
     * the folder list), as opposed to some side effect.
     */
    public async void select_folder(Convey.Folder? to_select,
                                    bool is_interactive,
                                    bool inhibit_autoselect = false) {
        if (this.selected_folder == to_select && !this.all_inboxes) {
            // Clicking the already-selected folder scrolls the
            // conversation list back to the top.
            if (is_interactive && to_select != null) {
                this.conversation_list_view.scroll_to_top();
            }
        } else {
            // Cancel any existing folder loading
            this.folder_open.cancel();
            var cancellable = this.folder_open = new GLib.Cancellable();

            this.conversation_list_selection_button.active = false;

            // Dispose of all existing objects for the currently
            // selected model.

            if (this.selected_folder != null) {
                this.progress_monitor.remove(this.selected_folder.opening_monitor);
                this.selected_folder.properties.notify.disconnect(update_headerbar);
                this.selected_folder = null;
            }
            if (this.conversations != null) {
                this.progress_monitor.remove(this.conversations.progress_monitor);
                close_conversation_monitor(this.conversations);
                this.conversations = null;
            }
            close_inbox_monitors();
            this.all_inboxes = false;
            this.searching_all_inboxes = false;
            this.conversation_list_view.set_monitors(null);

            this.conversation_list_info_bars.remove_all();

            // With everything disposed of, update existing window
            // state

            select_account(to_select != null ? to_select.account : null);
            this.selected_folder = to_select;
            foreach (var actions in this.folder_conversation_actions) {
                actions.source_folder = to_select;
            }

            // Ensure that the folder is selected in the UI if
            // this was called by something other than the
            // selection changed callback. That will check to
            // ensure that we're not setting it again.
            if (to_select != null) {
                // Prefer the inboxes branch if it is a thing, but
                // only for non-interactive calls
                if (is_interactive ||
                    (to_select.used_as != INBOX ||
                     !this.folder_list.select_inbox(to_select.account))) {
                    this.folder_list.select_folder(to_select);
                }
            } else {
                this.folder_list.deselect_folder();
            }

            update_title();
            update_conversation_actions(NONE);
            update_trash_action();

            if (to_select != null &&
                (to_select.used_as == TRASH || to_select.used_as == JUNK)) {
                this.conversation_viewer.show_none_selected();
            } else if (!this.composer_open) {
                this.conversation_viewer.show_loading();
            }
            this.previous_selection_was_interactive = is_interactive;

            debug("Folder selected: %s",
                  (to_select != null) ? to_select.to_string() : "(null)");

            // Not while a restore is pending, so that falling back to
            // the first inbox does not overwrite the one remembered
            if (to_select != null &&
                to_select.used_as == INBOX &&
                !this.restoring_last_inbox &&
                this.application.config.remember_last_inbox) {
                this.application.config.set_last_inbox(
                    to_select.account.information.id
                );
            }

            // Finally, hook up the new folder if any and start
            // loading conversations.

            if (to_select != null) {
                this.progress_monitor.add(to_select.opening_monitor);
                to_select.properties.notify.connect(update_headerbar);

                this.conversations = new Convey.App.ConversationMonitor(
                    to_select,
                    // Include fields for the conversation viewer as well so
                    // conversations can be displayed without having to go
                    // back to the db
                    ConversationList.View.REQUIRED_FIELDS |
                    ConversationListBox.REQUIRED_FIELDS |
                    ConversationEmail.REQUIRED_FOR_CONSTRUCT,
                    MIN_CONVERSATION_COUNT
                );
                this.progress_monitor.add(this.conversations.progress_monitor);

                if (inhibit_autoselect) {
                    this.conversation_list_view.inhibit_next_autoselect();
                }
                this.conversation_list_view.set_monitors(
                    Convey.Collection.single(this.conversations)
                );

                yield open_conversation_monitor(this.conversations, cancellable);
                yield this.controller.process_pending_composers();
            }
        }

        this.outer_view.show_content = false;
        close_folder_drawer();
        update_headerbar();
    }

    /**
     * Selects the combined view of every account's inbox.
     *
     * The inboxes are loaded with a conversation monitor each, since
     * folders, and hence conversation monitors, never span accounts.
     */
    public async void select_all_inboxes(bool is_interactive) {
        var inboxes = this.folder_list.get_all_inboxes();
        if (inboxes.size < 2) {
            select_first_inbox(is_interactive);
            return;
        }

        if (is_interactive && this.all_inboxes && !this.inbox_monitors.is_empty) {
            // Already showing them; clicking again scrolls back to the top
            this.conversation_list_view.scroll_to_top();
            this.outer_view.show_content = false;
            close_folder_drawer();
            return;
        }

        this.all_inboxes = true;
        if (this.application.config.remember_last_inbox) {
            this.application.config.set_last_inbox(Configuration.ALL_INBOXES);
        }
        this.folder_list.select_all_inboxes();
        update_title();

        yield show_folders(inboxes, is_interactive);
    }

    private async void show_folders(Gee.Collection<Convey.Folder> folders,
                                    bool is_interactive) {
        this.folder_open.cancel();
        var cancellable = this.folder_open = new GLib.Cancellable();

        this.conversation_list_selection_button.active = false;

        if (this.selected_folder != null) {
            this.progress_monitor.remove(this.selected_folder.opening_monitor);
            this.selected_folder.properties.notify.disconnect(update_headerbar);
            this.selected_folder = null;
        }
        if (this.conversations != null) {
            this.progress_monitor.remove(this.conversations.progress_monitor);
            close_conversation_monitor(this.conversations);
            this.conversations = null;
        }
        close_inbox_monitors();
        this.conversation_list_view.set_monitors(null);
        this.conversation_list_info_bars.remove_all();

        foreach (var actions in this.folder_conversation_actions) {
            actions.source_folder = null;
        }

        update_conversation_actions(NONE);
        update_trash_action();
        if (!this.composer_open) {
            this.conversation_viewer.show_loading();
        }
        this.previous_selection_was_interactive = is_interactive;

        foreach (var folder in folders) {
            var monitor = new Convey.App.ConversationMonitor(
                folder,
                ConversationList.View.REQUIRED_FIELDS |
                ConversationListBox.REQUIRED_FIELDS |
                ConversationEmail.REQUIRED_FOR_CONSTRUCT,
                MIN_CONVERSATION_COUNT
            );
            this.inbox_monitors.add(monitor);
            this.progress_monitor.add(monitor.progress_monitor);
        }
        this.conversation_list_view.set_monitors(this.inbox_monitors);

        // Iterated over a copy, since closing the window clears the
        // monitors while this is still opening them
        var opening = new Gee.ArrayList<Convey.App.ConversationMonitor>();
        opening.add_all(this.inbox_monitors);
        foreach (var monitor in opening) {
            if (cancellable.is_cancelled()) {
                return;
            }
            yield open_conversation_monitor(monitor, cancellable);
        }
        yield this.controller.process_pending_composers();

        this.outer_view.show_content = false;
        close_folder_drawer();
        update_headerbar();
    }

    private void close_inbox_monitors() {
        foreach (var monitor in this.inbox_monitors) {
            this.progress_monitor.remove(monitor.progress_monitor);
            close_conversation_monitor(monitor);
        }
        this.inbox_monitors.clear();
    }

    /**
     * Groups conversations by the folder actions on them apply to.
     *
     * Conversations in the combined inbox view come from several
     * accounts, so an action runs once per source folder.
     */
    private Gee.MultiMap<Convey.Folder,Convey.App.Conversation>
        group_by_folder(Gee.Collection<Convey.App.Conversation> conversations) {
        var groups =
            new Gee.HashMultiMap<Convey.Folder,Convey.App.Conversation>();
        foreach (var conversation in conversations) {
            Convey.Folder? location = (
                this.selected_folder ?? conversation.base_folder
            );
            if (location != null) {
                groups.set(location, conversation);
            }
        }
        return groups;
    }

    // The selected conversations, grouped by the folder actions apply to
    private Gee.MultiMap<Convey.Folder,Convey.App.Conversation>
        selected_groups() {
        return group_by_folder(this.conversation_list_view.selected);
    }

    /** Selects the given account, folder and conversations. */
    public async void show_conversations(Convey.Folder location,
                                         Gee.Collection<Convey.App.Conversation> to_show,
                                         bool is_interactive) {
        bool inhibit_autoselect = (location != this.selected_folder);
        yield select_folder(location, is_interactive, inhibit_autoselect);
        // The folder may have changed again by the type the async
        // call returns, so only continue if still current
        if (this.selected_folder == location) {
            this.outer_view.show_content = true;

            // Since conversation ids don't persist between
            // conversation monitor instances, need to load
            // conversations based on their messages.
            var latest_email = new Gee.HashSet<Convey.EmailIdentifier>();
            foreach (var stale in to_show) {
                Convey.Email? first = stale.get_latest_recv_email(IN_FOLDER);
                if (first != null) {
                    latest_email.add(first.id);
                }
            }
            var loaded = yield load_conversations_for_email(
                location, latest_email
            );
            if (!loaded.is_empty) {
                yield select_conversations(
                    loaded,
                    Gee.Collection.empty<Convey.EmailIdentifier>(),
                    is_interactive
                );
            }
        }
    }

    /** Selects the given account, folder and email. */
    public async void show_email(Convey.Folder location,
                                 Gee.Collection<Convey.EmailIdentifier> to_show,
                                 bool is_interactive) {
        bool inhibit_autoselect = (location != this.selected_folder);
        yield select_folder(location, is_interactive, inhibit_autoselect);
        // The folder may have changed again by the type the async
        // call returns, so only continue if still current
        if (this.selected_folder == location) {
            var loaded = yield load_conversations_for_email(location, to_show);

            this.outer_view.show_content = true;
            if (loaded.size == 1) {
                // A single conversation was loaded, so ensure we
                // scroll to the email in the conversation.
                Convey.App.Conversation? target = Convey.Collection.first(loaded);
                ConversationListBox? current_list =
                    this.conversation_viewer.current_list;
                if (current_list != null &&
                    current_list.conversation == target) {
                    // The target conversation is already loaded, just
                    // scroll to the messages.
                    //
                    // This is actually racy, since the view may
                    // still be in the middle of loading the messages
                    // obtained from the conversation monitor when
                    // this call is made.
                    current_list.scroll_to_messages(to_show);
                } else {
                    // The target conversation is not loaded, select
                    // it and scroll to the messages.
                    yield select_conversations(loaded, to_show, is_interactive);
                }
            } else if (!loaded.is_empty) {
                // Multiple conversations found, just select those
                yield select_conversations(
                    loaded,
                    Gee.Collection.empty<Convey.EmailIdentifier>(),
                    is_interactive
                );
            }
        }
    }

    /** Shows the appopriate window menu, if any. */
    public void show_window_menu() {
        this.outer_view.show_content = false;
        this.inner_view.show_sidebar = true;
        this.app_menu_button.active = true;
    }

    /** Displays and focuses the search bar for the window. */
    public void show_search_bar(string? text = null) {
        this.outer_view.show_content = false;
        close_folder_drawer();

        this.search_bar.search_mode_enabled = true;
        this.search_bar.grab_focus();
        if (text != null) {
            this.search_bar.entry.text = text;
        }
    }

    /** Displays an infobar in the window. */
    public void show_info_bar(Components.InfoBar info_bar) {
        if (!this.info_bars.has_current) {
            this.info_bars.add(info_bar);
        }
    }

    /**
     * Displays a composer in the window if possible, else in a new window.
     */
    internal void show_composer(Composer.Widget composer) {
        if (this.has_composer) {
            composer.detach(this.application);
        } else {
            // See if the currently displayed conversation contains
            // any of the composer's referred emails (preferring the
            // latest), and if so add it inline, otherwise add it full
            // paned.
            Convey.Email? latest_referred = null;
            if (this.conversation_viewer.current_list != null) {
                Convey.App.Conversation selected =
                    this.conversation_viewer.current_list.conversation;
                // When editing an existing draft, use the draft email
                // itself as the anchor so the composer appears at the
                // draft's position rather than the parent message's
                // position (restore_reply_to_state adds the parent's
                // ID to referred_ids, which would place the composer
                // one row too high).
                if (composer.saved_id != null) {
                    var draft_id = composer.saved_id;
                    latest_referred = selected.get_emails(
                        RECV_DATE_DESCENDING
                    ).first_match(
                        (email) => email.id.equal_to(draft_id)
                    );
                }
                if (latest_referred == null) {
                    Gee.Collection<Convey.EmailIdentifier>? referrants =
                        composer.get_referred_ids();
                    latest_referred = selected.get_emails(
                        RECV_DATE_DESCENDING
                    ).first_match(
                        (email) => email.id in referrants
                    );
                }
            }

            if (latest_referred != null) {
                this.conversation_viewer.do_compose_embedded(
                    composer, latest_referred
                );
            } else {
                this.conversation_viewer.do_compose(composer);
            }
            // Show the correct view
            this.outer_view.show_content = true;
        }
    }

    /**
     * Closes any open composers, after prompting the user if requested.
     *
     * Returns true if none were open or the user approved closing
     * them.
     */
    internal bool close_composer(bool should_prompt, bool is_shutdown = false) {
        Composer.Widget? composer = this.conversation_viewer.current_composer;
        if (composer == null) {
            return true;
        }
        if (!should_prompt) {
            // Without a prompt this saves or discards as appropriate
            // and always closes, so it can run in the background
            composer.conditional_close.begin(false, is_shutdown);
            return true;
        }
        // Prompting requires an async dialog; kick it off and report
        // not-closed so the caller doesn't proceed prematurely
        composer.conditional_close.begin(true, is_shutdown);
        return false;
    }

    internal void start_search(string query_text, bool is_interactive) {
        if (this.all_inboxes) {
            var folders = new Gee.ArrayList<Convey.Folder>();
            foreach (var account in this.controller.get_account_contexts()) {
                try {
                    var expr_factory = new Util.Email.SearchExpressionFactory(
                        this.application.config.get_search_strategy(),
                        account.account.information
                    );
                    account.search.update_query(
                        account.account.new_search_query(
                            expr_factory.parse_query(query_text),
                            query_text
                        )
                    );
                    folders.add(account.search);
                } catch (GLib.Error error) {
                    handle_error(account.account.information, error);
                }
            }
            if (!this.searching_all_inboxes) {
                this.searching_all_inboxes = true;
                this.show_folders.begin(folders, is_interactive);
            }
            return;
        }

        var context = get_selected_account_context();
        if (context != null) {
            // If the current folder is not the search folder, save it
            // so it can be re-selected later when search is closed
            if (this.previous_non_search_folder == null &&
                this.selected_folder != null &&
                this.selected_folder.used_as != SEARCH) {
                this.previous_non_search_folder = this.selected_folder;
            }

            try {
                var expr_factory = new Util.Email.SearchExpressionFactory(
                    this.application.config.get_search_strategy(),
                    context.account.information
                );
                var query = context.account.new_search_query(
                    expr_factory.parse_query(query_text),
                    query_text
                );
                this.folder_list.set_search(
                    this.application.engine, context.search
                );
                context.search.update_query(query);
            } catch (GLib.Error error) {
                handle_error(context.account.information, error);
            }
        }
    }

    internal void stop_search(bool is_interactive) {
        if (this.searching_all_inboxes) {
            this.searching_all_inboxes = false;
            this.select_all_inboxes.begin(false);
        }
        // If the search folder is current selected, deselect and
        // re-select any previously selected folder
        if (!this.all_inboxes &&
            (this.selected_folder == null ||
             this.selected_folder.used_as == SEARCH)) {
            var to_select = this.previous_non_search_folder;
            if (to_select == null) {
                var account = get_selected_account_context();
                if (account != null) {
                    to_select = account.inbox;
                }

            }
            this.previous_non_search_folder = null;
            if (to_select != null) {
                this.select_folder.begin(
                    to_select, is_interactive
                );
            } else {
                select_first_inbox(is_interactive);
            }
        }
        this.folder_list.remove_search();

        foreach (var context in this.controller.get_account_contexts()) {
            context.search.clear_query();
        }
    }

    /**
     * Selects the inbox last opened, or the first one as a fallback.
     *
     * Returns false if nothing could be selected yet, so that callers
     * can try again once the account has finished loading folders.
     */
    internal bool select_startup_inbox(bool is_interactive) {
        return (
            restore_last_inbox(is_interactive) ||
            (!waiting_for_all_inboxes() && select_first_inbox(is_interactive))
        );
    }

    private bool waiting_for_all_inboxes() {
        if (this.all_inboxes_wait_over ||
            this.application.config.get_last_inbox() != Configuration.ALL_INBOXES) {
            return false;
        }
        try {
            if (this.application.engine.get_accounts().size <= 1) {
                return false;
            }
        } catch (GLib.Error error) {
            return false;
        }
        if (!this.all_inboxes_wait.is_running) {
            this.all_inboxes_wait.start();
        }
        return true;
    }

    private void on_all_inboxes_wait_over() {
        this.all_inboxes_wait_over = true;
        if (this.restoring_last_inbox) {
            select_startup_inbox(false);
        }
    }

    // Selects the inbox remembered from last session, if it has loaded
    private bool restore_last_inbox(bool is_interactive) {
        string last = this.application.config.get_last_inbox();
        if (last == Configuration.ALL_INBOXES) {
            if (this.folder_list.get_all_inboxes().size < 2) {
                return false;
            }
            this.restoring_last_inbox = false;
            this.select_all_inboxes.begin(is_interactive);
            return true;
        }

        Convey.Folder? inbox = get_inbox_for_account(last);
        if (inbox == null) {
            return false;
        }
        this.restoring_last_inbox = false;
        return select_inbox(inbox, is_interactive);
    }

    private bool select_first_inbox(bool is_interactive) {
        return select_inbox(get_first_inbox(), is_interactive);
    }

    private bool select_inbox(Convey.Folder? inbox, bool is_interactive) {
        if (inbox == null) {
            return false;
        }
        this.select_folder.begin(inbox, is_interactive);
        return true;
    }

    private Convey.Folder? get_inbox_for_account(string id) {
        Convey.Folder? inbox = null;
        try {
            foreach (var account in this.application.engine.get_accounts()) {
                if (account.information.id == id) {
                    inbox = account.get_special_folder(INBOX);
                    break;
                }
            }
        } catch (GLib.Error error) {
            debug("Error getting inbox for account %s: %s", id, error.message);
        }
        return inbox;
    }

    private void add_account(AccountContext to_add) {
        if (!this.accounts.contains(to_add)) {
            this.folder_list.set_user_folders_root_name(
                to_add.account, _("Labels")
            );

            this.progress_monitor.add(to_add.account.background_progress);
            Convey.Smtp.ClientService? smtp = (
                to_add.account.outgoing as Convey.Smtp.ClientService
            );
            if (smtp != null) {
                this.progress_monitor.add(smtp.sending_monitor);
            }

            to_add.folders_available.connect(on_folders_available);
            to_add.folders_unavailable.connect(on_folders_unavailable);
            to_add.commands.executed.connect(on_command_execute);
            to_add.account.information.changed.connect(update_trash_action);
            to_add.commands.undone.connect(on_command_undo);
            to_add.commands.redone.connect(on_command_redo);

            // Sort the folders so FolderListTree adds them all
            // correctly
            var added = new Gee.TreeSet<FolderContext>();
            added.add_all(to_add.get_folders());

            // Register the account before adding folders so anything
            // resolving the selected folder's context (e.g. the
            // window title) can find it
            this.accounts.add(to_add);
            add_folders(added);
        }
    }

    /**
     * Removes the given account from the main window.
     *
     * If `to_select` is not null, the given folder will be selected,
     * otherwise no folder will be.
     */
    private async void remove_account(AccountContext to_remove,
                                      Convey.Folder? to_select) {
        if (this.accounts.contains(to_remove)) {
            // Explicitly unset the selected folder if it belongs to the
            // account so we block until it's gone. This also clears the
            // previous search folder, so it won't try to re-load that
            // that when the account is gone.
            if (this.selected_folder != null &&
                this.selected_folder.account == to_remove.account) {
                bool is_account_search_active = (
                    this.selected_folder.used_as == SEARCH
                );

                yield select_folder(to_select, false);

                if (is_account_search_active) {
                    this.search_bar.entry.text = "";
                    this.search_bar.search_mode_enabled = false;
                }
            }

            to_remove.commands.executed.disconnect(on_command_execute);
            to_remove.account.information.changed.disconnect(update_trash_action);
            to_remove.commands.undone.disconnect(on_command_undo);
            to_remove.commands.redone.disconnect(on_command_redo);
            to_remove.folders_available.disconnect(on_folders_available);
            to_remove.folders_available.disconnect(on_folders_unavailable);

            this.progress_monitor.remove(to_remove.account.background_progress);
            Convey.Smtp.ClientService? smtp = (
                to_remove.account.outgoing as Convey.Smtp.ClientService
            );
            if (smtp != null) {
                this.progress_monitor.remove(smtp.sending_monitor);
            }

            // Finally, remove the account and its folders
            remove_folders(to_remove.get_folders(), false);
            this.folder_list.remove_account(to_remove.account);
            this.accounts.remove(to_remove);
        }
    }

    /** Adds a folder to the window. */
    private void add_folders(Gee.Collection<FolderContext> to_add) {
        // Build map between path and display name for
        // special directories
        var map = new Gee.HashMap<string,string>();
        foreach (var context in to_add) {
            var folder = context.folder;
            if (folder.used_as == Convey.Folder.SpecialUse.NONE)
                continue;
            map.set(
                folder.path.to_string().substring(1),
                context.display_name
            );
        }
        foreach (var context in to_add) {
            this.folder_list.add_folder(context);
            context.folder.use_changed.connect(on_use_changed);
        }

        // The selected folder may have been opened before its entry
        // (or account context) existed here, leaving the sidebar
        // unselected and the title empty; sync them now
        foreach (var context in to_add) {
            if (context.folder == this.selected_folder) {
                this.folder_list.select_folder(context.folder);
                update_title();
                break;
            }
        }

        if (Convey.traverse(to_add).any((c) => c.folder.used_as == INBOX)) {
            if (this.all_inboxes) {
                this.select_all_inboxes.begin(false);
            } else if (this.restoring_last_inbox) {
                restore_last_inbox(false);
            }
        }
    }

    /** Removes a folder from the window. */
    private void remove_folders(Gee.Collection<FolderContext> to_remove,
                                bool update_selecton) {
        bool reload_all_inboxes = false;
        foreach (var context in to_remove) {
            Convey.Folder folder = context.folder;
            if (this.selected_folder == folder) {
                var account = get_selected_account_context();
                if (account != null) {
                    this.select_folder.begin(account.inbox, true);
                }
            }
            if (this.all_inboxes && folder.used_as == INBOX) {
                reload_all_inboxes = true;
            }

            folder.use_changed.disconnect(on_use_changed);
            this.folder_list.remove_folder(context);
        }

        if (reload_all_inboxes) {
            this.select_all_inboxes.begin(false);
        }
    }

    private AccountContext? get_selected_account_context() {
        AccountContext? context = null;
        if (this.selected_account != null) {
            context = this.controller.get_context_for_account(
                this.selected_account.information
            );
        }
        return context;
    }

    private Convey.Folder? get_first_inbox() {
        Convey.Folder? inbox = null;
        try {
            Convey.Account? first = Convey.Collection.first<Convey.Account>(
                this.application.engine.get_accounts()
            );
            if (first != null) {
                inbox = first.get_special_folder(INBOX);
            }
        } catch (GLib.Error error) {
            debug("Error getting inbox for first account");
        }
        return inbox;
    }

    private void load_config(Configuration config) {
        // This code both loads AND saves the pane positions with live updating. This is more
        // resilient against crashes because the value in dconf changes *immediately*, and
        // stays saved in the event of a crash.
        config.bind(Configuration.WINDOW_WIDTH_KEY, this, "window-width");
        config.bind(Configuration.WINDOW_HEIGHT_KEY, this, "window-height");
        config.bind(Configuration.WINDOW_MAXIMIZE_KEY, this, "maximized");
    }

    private void restore_saved_window_state() {
        // The window isn't realized yet, so there's no monitor to
        // sanity-check the size against; the compositor will clamp
        // over-size windows anyway.
        if (this.window_width > 0 && this.window_height > 0) {
            set_default_size(this.window_width, this.window_height);
        }
        if (this.maximized) {
            maximize();
        }
    }

    public override bool close_request() {
        // Any composer prompt and the final teardown are async, so
        // always inhibit the close here and destroy the window
        // ourselves when ready
        this.do_close_request.begin();
        return true;
    }

    private async void do_close_request() {
        Composer.Widget? composer = this.conversation_viewer.current_composer;
        if (composer != null &&
            (yield composer.conditional_close(true, false)) == CANCELLED) {
            return;
        }

        this.window_width = this.default_width;
        this.window_height = this.default_height;

        if (this.application != null) {
            this.controller.account_available.disconnect(
                on_account_available
            );
            this.controller.account_unavailable.disconnect(
                on_account_unavailable
            );
        }
        this.update_ui_timeout.reset();
        this.all_inboxes_wait.reset();

        this.sensitive = false;
        this.select_folder.begin(
            null,
            false,
            true,
            (obj, res) => {
                this.select_folder.end(res);
                destroy();
            }
        );
    }

    public void add_toast(Adw.Toast toast) {
        toast.priority = Adw.ToastPriority.HIGH;
        this.overlay.add_toast(toast);
    }

    private void setup_layout(Configuration config) {
        this.notify["has-toplevel-focus"].connect(on_has_toplevel_focus);

        this.sidebar_resize_handle.set_cursor_from_name("col-resize");
        var sidebar_drag = new Gtk.GestureDrag();
        sidebar_drag.propagation_phase = CAPTURE;
        sidebar_drag.drag_begin.connect(on_sidebar_drag_begin);
        sidebar_drag.drag_update.connect(on_sidebar_drag_update);
        sidebar_drag.drag_end.connect(() => {
            if (this.sidebar_dragged) {
                config.sidebar_width_fraction = this.outer_view.sidebar_width_fraction;
            }
        });
        this.outer_view.add_controller(sidebar_drag);

        this.default_min_sidebar_width = (int) this.outer_view.min_sidebar_width;
        this.default_max_sidebar_width = (int) this.outer_view.max_sidebar_width;
        this.default_sidebar_width_fraction = this.outer_view.sidebar_width_fraction;
        if (config.sidebar_width_fraction > 0) {
            this.outer_view.min_sidebar_width = 360;
            this.outer_view.max_sidebar_width = int.MAX;
            this.outer_view.sidebar_width_fraction = config.sidebar_width_fraction;
        }
        var sidebar_reset = new Gtk.GestureClick();
        sidebar_reset.pressed.connect((n_press, x, y) => {
            if (n_press == 2) {
                this.outer_view.min_sidebar_width = this.default_min_sidebar_width;
                this.outer_view.max_sidebar_width = this.default_max_sidebar_width;
                this.outer_view.sidebar_width_fraction = this.default_sidebar_width_fraction;
                config.sidebar_width_fraction = 0;
            }
        });
        this.sidebar_resize_handle.add_controller(sidebar_reset);

        this.folder_resize_handle.set_cursor_from_name("col-resize");
        var folder_drag = new Gtk.GestureDrag();
        folder_drag.propagation_phase = CAPTURE;
        folder_drag.drag_begin.connect(on_folder_drag_begin);
        folder_drag.drag_update.connect(on_folder_drag_update);
        folder_drag.drag_end.connect(() => {
            if (this.folder_list_dragged) {
                config.folder_list_width = (int) this.inner_view.max_sidebar_width;
            }
        });
        this.inner_view.add_controller(folder_drag);

        this.default_folder_list_width = (int) this.inner_view.min_sidebar_width;
        if (config.folder_list_width > 0) {
            set_folder_list_width(config.folder_list_width);
        }
        var folder_reset = new Gtk.GestureClick();
        folder_reset.pressed.connect((n_press, x, y) => {
            if (n_press == 2) {
                set_folder_list_width(this.default_folder_list_width);
                config.folder_list_width = 0;
            }
        });
        this.folder_resize_handle.add_controller(folder_reset);

        // Search bar
        this.search_bar = new SearchBar(this.application.engine);
        this.search_bar.search_text_changed.connect(on_search);
        this.conversation_list_box.append(this.search_bar);


        // Folder list
        this.folder_list.set_collapsed(
            this.application.config.get_collapsed_folder_groups()
        );
        this.folder_list.expansion_changed.connect(on_folder_expansion_changed);
        this.folder_list.user_interacted.connect(
            () => this.restoring_last_inbox = false
        );
        this.folder_list.folder_selected.connect(on_folder_selected);
        this.folder_list.all_inboxes_selected.connect(on_all_inboxes_selected);
        this.folder_list.all_inboxes_activated.connect(on_all_inboxes_activated);
        this.folder_list.move_conversation.connect(on_move_conversation);
        this.folder_list.copy_conversation.connect(on_copy_conversation);
        this.folder_list.folder_activated.connect(on_folder_activated);
        this.folder_list.folder_rename.connect(on_folder_rename_requested);
        this.folder_list.folder_delete.connect(on_folder_delete_requested);
        this.folder_list_scrolled.child = this.folder_list;
        setup_folder_context_menu();

        // Conversation list
        this.conversation_list_box.append(this.conversation_list_info_bars);

        this.conversation_list_view = new ConversationList.View(
            this.application.config, this.application.decrypted_subjects
        );
        this.conversation_list_view.mark_conversations.connect(on_mark_conversations);
        this.conversation_list_view.conversations_selected.connect(on_conversations_selected);
        this.conversation_list_view.conversation_activated.connect(on_conversation_activated);
        this.conversation_list_view.visible_conversations.notify.connect(on_visible_conversations_changed);
        this.conversation_list_view.mail_drag_active.connect(
            on_mail_drag_active
        );
        this.conversation_list_view.scrolled_window.vadjustment.value_changed.connect(
            update_header_divider
        );
        this.conversation_list_view.vexpand = true;

        this.conversation_list_box.append(this.conversation_list_view);

        // Conversation viewer
        this.conversation_viewer = new ConversationViewer(
            this.application.config, this.application.decrypted_subjects
        );
        this.conversation_viewer.conversation_added.connect(
            on_conversation_view_added
        );

        this.conversation_viewer.hexpand = true;
        this.conversation_viewer.vexpand = true;
        this.conversation_viewer.notify["empty-page"].connect(update_empty_message);
        this.empty_overlay.get_child_position.connect(on_empty_overlay_position);
        this.conversation_viewer.conversation_scroller.vadjustment.value_changed.connect(
            update_header_divider
        );
        this.conversation_viewer_box.prepend(this.conversation_viewer);
        this.conversation_viewer_actions_revealer.bind_property(
            "reveal-child", this.conversation_viewer.headerbar, "compact", SYNC_CREATE
        );

        // Left/Right walk the keyboard focus across the panes. The
        // conversation viewer gets no handler of its own: its message
        // bodies and composers want the arrow keys for themselves.
        setup_pane_navigation(
            this.folder_list, null, this.conversation_list_view
        );
        setup_pane_navigation(
            this.conversation_list_view,
            this.folder_list,
            this.conversation_viewer
        );

        this.conversation_list_selection_button.bind_property(
            "active",
            this.conversation_list_view, "selection-mode-enabled",
            SYNC_CREATE | BIDIRECTIONAL
        );
        this.search_button.bind_property(
            "active",
            this.search_bar, "search-mode-enabled",
            SYNC_CREATE | BIDIRECTIONAL
        );
        this.search_bar.unread_button.bind_property(
            "active",
            this.conversation_list_view, "unread-only",
            SYNC_CREATE
        );
        this.bind_property(
            "all-inboxes",
            this.search_bar, "all-accounts",
            SYNC_CREATE
        );
        this.conversation_viewer.headerbar.bind_property(
            "find-open",
            this.conversation_viewer.conversation_find_bar, "search-mode-enabled",
            SYNC_CREATE | BIDIRECTIONAL
        );
        this.conversation_list_selection_button.notify["active"].connect(
            (obj, pspec) => {
                // Only show revealer with bottom actions in narrow mode
                if (this.conversation_list_view.selection_mode_enabled)
                    this.conversation_list_actions_revealer.reveal_child = (
                        this.inner_view.collapsed);
                else
                    this.conversation_list_actions_revealer.reveal_child = false;
            }
        );

        progress_monitor.start.connect(() => headerbar_push_busy());
        progress_monitor.finish.connect(() => headerbar_pop_busy());
        this.refresh_button.clicked.connect(on_refresh_folder);
        this.notify["all-inboxes"].connect(() => update_command_actions());
        this.notify["focus-widget"].connect(() => update_command_actions());

        this.conversation_list_actions.set_menus_inverted();
        this.conversation_viewer_actions.set_menus_inverted();
        this.conversation_viewer_actions.show_button_labels();

        this.conversation_viewer.headerbar.left_actions.init(this.application.config);
        this.conversation_viewer.headerbar.right_actions.init(this.application.config);
        this.conversation_list_actions.init(this.application.config);
        this.conversation_viewer_actions.init(this.application.config);

        this.folder_conversation_actions = {
            this.conversation_viewer.headerbar.left_actions,
            this.conversation_viewer.headerbar.right_actions,
            this.conversation_list_actions,
            this.conversation_viewer_actions
        };

        foreach (var actions in this.folder_conversation_actions) {
            actions.copy_popover.copy_conversation.connect(on_copy_conversation);
            actions.move_popover.move_conversation.connect(on_move_conversation);
        }
    }

    [GtkCallback]
    private bool on_key_pressed(Gtk.EventControllerKey controller,
                                uint keyval,
                                uint keycode,
                                Gdk.ModifierType state) {
        check_shift_event(keyval, true);
        var composer = get_focus()?.get_ancestor(
            typeof(Composer.Widget)
        ) as Composer.Widget;
        if (keyval == Gdk.Key.Escape && composer != null) {
            composer.conditional_close.begin(false);
            return true;
        }
        if (keyval == Gdk.Key.Escape &&
            !this.has_composer &&
            this.conversation_list_view.selected.size > 0) {
            this.conversation_list_view.unselect_all();
            return true;
        }
        return false;
    }

    [GtkCallback]
    private void on_key_released(uint keyval, uint keycode, Gdk.ModifierType state) {
        check_shift_event(keyval, false);
    }

    //
    // Folder management
    //

    private void setup_folder_context_menu() {
        var popover = new Gtk.PopoverMenu.from_model(
            new_folder_menu_model(false, false)
        ) {
            has_arrow = false,
            halign = START
        };
        popover.set_parent(this.folder_list);
        this.folder_list.default_context_menu = popover;

        // The Inboxes section spans accounts, so there is no single
        // folder to manage there — offer the accounts editor instead.
        var inboxes_menu = new GLib.Menu();
        // Translators: Folder list context menu item opening the
        // accounts editor
        inboxes_menu.append(_("_Manage Accounts…"), "app.accounts");
        var inboxes_popover = new Gtk.PopoverMenu.from_model(inboxes_menu) {
            has_arrow = false,
            halign = START
        };
        inboxes_popover.set_parent(this.folder_list);
        this.folder_list.set_inboxes_context_menu(inboxes_popover);

        this.folder_list.context_menu_requested.connect(
            on_folder_context_menu_requested
        );
    }

    private GLib.Menu new_folder_menu_model(bool labels, bool child) {
        var menu = new GLib.Menu();
        menu.append(
            // Translators: Folder list context menu item for creating
            // a new folder, and the label equivalent
            labels ? _("_New Label…") : _("_New Folder…"),
            "win." + ACTION_FOLDER_NEW
        );
        if (child) {
            menu.append(
                // Translators: Folder list context menu item for
                // creating a folder inside the folder that was
                // right-clicked, and the label equivalent
                labels ? _("_New Sublabel…") : _("_New Subfolder…"),
                "win." + ACTION_FOLDER_NEW_CHILD
            );
        }
        menu.append(
            // Translators: Folder list context menu item for renaming
            // a folder, and the label equivalent
            labels ? _("_Rename Label…") : _("_Rename Folder…"),
            "win." + ACTION_FOLDER_RENAME
        );
        menu.append(
            // Translators: Folder list context menu item for deleting
            // a folder, and the label equivalent
            labels ? _("_Delete Label") : _("_Delete Folder"),
            "win." + ACTION_FOLDER_DELETE
        );
        return menu;
    }

    /** The folder the folder list's context menu was invoked on, if any. */
    private Convey.Folder? get_context_folder() {
        var entry = (
            this.folder_list.context_entry as FolderList.AbstractFolderEntry
        );
        return (entry != null) ? entry.folder : null;
    }

    /** The account to create new folders in, if any. */
    private Convey.Account? get_context_account() {
        Convey.Folder? folder = get_context_folder();
        if (folder != null) {
            return folder.account;
        }
        var entry = this.folder_list.context_entry;
        return (entry != null)
            ? this.folder_list.get_account_for_entry(entry)
            : null;
    }

    private void on_folder_context_menu_requested(Sidebar.Entry? entry) {
        Convey.Account? account = get_context_account();
        Convey.Folder? folder = get_context_folder();
        if (account != null) {
            this.folder_list.default_context_menu.menu_model =
                new_folder_menu_model(
                    Util.I18n.uses_labels(account), folder != null
                );
        }

        bool is_user_folder = (folder != null && folder.used_as == NONE);

        ((GLib.SimpleAction) lookup_action(ACTION_FOLDER_NEW)).set_enabled(
            account != null
        );
        ((GLib.SimpleAction) lookup_action(ACTION_FOLDER_NEW_CHILD)).set_enabled(
            folder != null
        );
        ((GLib.SimpleAction) lookup_action(ACTION_FOLDER_RENAME)).set_enabled(
            is_user_folder
        );
        ((GLib.SimpleAction) lookup_action(ACTION_FOLDER_DELETE)).set_enabled(
            is_user_folder
        );
    }

    private void on_folder_new() {
        Convey.Account? account = get_context_account();
        if (account != null) {
            create_folder.begin(account, null);
        }
    }

    private void on_folder_new_child() {
        Convey.Folder? folder = get_context_folder();
        if (folder != null) {
            create_folder.begin(folder.account, folder);
        }
    }

    private void on_folder_rename() {
        var entry = this.folder_list.context_entry;
        if (entry != null) {
            // Falls back to the inline editor, which calls back in
            // via on_folder_rename_requested
            this.folder_list.rename_entry_in_place(entry);
        }
    }

    private void on_folder_delete() {
        Convey.Folder? folder = get_context_folder();
        if (folder != null) {
            delete_folder.begin(folder);
        }
    }

    private void on_folder_rename_requested(Convey.Folder folder,
                                            string new_name) {
        rename_folder.begin(folder, new_name);
    }

    private void on_folder_delete_requested(Convey.Folder folder) {
        delete_folder.begin(folder);
    }

    private async void create_folder(Convey.Account account,
                                     Convey.Folder? parent) {
        bool labels = Util.I18n.uses_labels(account);
        var entry = new Gtk.Entry() { activates_default = true };
        var dialog = new Adw.AlertDialog(
            // Translators: Title of the new folder dialog, and the
            // label equivalent
            labels
                ? _("New Label")
                : (parent != null ? _("New Subfolder") : _("New Folder")),
            null
        );
        dialog.extra_child = entry;
        dialog.focus_widget = entry;
        dialog.add_response("cancel", _("_Cancel"));
        dialog.add_response("create", _("_Create"));
        dialog.default_response = "create";
        dialog.close_response = "cancel";
        dialog.set_response_appearance("create", Adw.ResponseAppearance.SUGGESTED);

        string response = yield dialog.choose(this, null);
        string name = entry.text.strip();
        if (response != "create" || name == "") {
            return;
        }

        // Show the folder straight away, dimmed and spinning, so the
        // round trip to the server isn't silent
        var pending = this.folder_list.add_pending_folder(account, name, parent);
        try {
            yield account.create_personal_folder(name, NONE, null, parent);
            add_toast(new Adw.Toast(
                // Translators: Toast shown once a folder has been
                // created on the server, and the label equivalent.
                // Substitution is the folder name.
                (labels
                 ? _("Created label “%s”")
                 : _("Created folder “%s”")).printf(name)
            ));
        } catch (GLib.Error err) {
            handle_error(account.information, err);
        } finally {
            if (pending != null) {
                this.folder_list.remove_pending_folder(account, pending);
            }
        }
    }

    private async void rename_folder(Convey.Folder folder, string new_name) {
        bool labels = Util.I18n.uses_labels(folder.account);
        string old_name = folder.path.name;
        this.folder_list.set_folder_busy(folder, true);
        try {
            yield folder.account.rename_folder(folder, new_name, null);
            add_toast(new Adw.Toast(
                // Translators: Toast shown once a folder has been
                // renamed on the server, and the label equivalent.
                // Substitutions are the old and new names.
                (labels
                 ? _("Renamed label “%s” to “%s”")
                 : _("Renamed folder “%s” to “%s”")).printf(
                     old_name, new_name
                 )
            ));
        } catch (GLib.Error err) {
            handle_error(folder.account.information, err);
        } finally {
            this.folder_list.set_folder_busy(folder, false);
        }
    }

    private async void delete_folder(Convey.Folder folder) {
        bool labels = Util.I18n.uses_labels(folder.account);
        var dialog = new Adw.AlertDialog(
            // Translators: Title of the delete folder confirmation and
            // the label equivalent, substitution is the folder name
            (labels
             ? _("Delete label “%s”?")
             : _("Delete folder “%s”?")).printf(folder.path.name),
            (labels
             ? _("This removes the label and all email in it from Convey and your email server.")
             : _("This removes the folder and all email in it from Convey and your email server.")) +
            "  <b>" + _("This cannot be undone.") + "</b>"
        );
        dialog.body_use_markup = true;
        dialog.add_response("cancel", _("_Cancel"));
        dialog.add_response("delete", _("_Delete"));
        // Delete is the default, as in Files; Esc still cancels
        dialog.default_response = "delete";
        dialog.close_response = "cancel";
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);

        if ((yield dialog.choose(this, null)) != "delete") {
            return;
        }

        string name = folder.path.name;
        this.folder_list.set_folder_busy(folder, true);
        try {
            yield folder.account.delete_folder(folder, null);
            add_toast(new Adw.Toast(
                // Translators: Toast shown once a folder has been
                // deleted from the server, and the label equivalent.
                // Substitution is the folder name.
                (labels
                 ? _("Deleted label “%s”")
                 : _("Deleted folder “%s”")).printf(name)
            ));
        } catch (GLib.Error err) {
            handle_error(folder.account.information, err);
        } finally {
            this.folder_list.set_folder_busy(folder, false);
        }
    }

    internal async bool prompt_empty_folder(Convey.Folder.SpecialUse type) {
        var folder_name = Util.I18n.to_folder_type_display_name(type);
        var dialog = new Adw.AlertDialog(
            _("Empty all email from your %s folder?").printf(folder_name),
            _("This removes the email from Convey and your email server.") +
            "  <b>" + _("This cannot be undone.") + "</b>");
        dialog.body_use_markup = true;
        dialog.add_response("cancel", _("_Cancel"));
        dialog.add_response("confirm", _("Empty %s").printf(folder_name));
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        dialog.set_response_appearance("confirm", Adw.ResponseAppearance.DESTRUCTIVE);
        string response = yield dialog.choose(this, null);
        return (response == "confirm");
    }

    /** Un-does the last executed application command, if any. */
    private async void undo() {
        AccountContext? selected = get_command_context(true);
        if (selected != null) {
            selected.commands.undo.begin(
                selected.cancellable,
                (obj, res) => {
                    try {
                        selected.commands.undo.end(res);
                        if (this.all_inboxes) {
                            on_refresh_folder();
                        }
                    } catch (GLib.Error err) {
                        handle_error(selected.account.information, err);
                    }
                }
            );
        }
    }

    /** Re-does the last undone application command, if any. */
    private async void redo() {
        AccountContext? selected = get_command_context(false);
        if (selected != null) {
            selected.commands.redo.begin(
                selected.cancellable,
                (obj, res) => {
                    try {
                        selected.commands.redo.end(res);
                        if (this.all_inboxes) {
                            on_refresh_folder();
                        }
                    } catch (GLib.Error err) {
                        handle_error(selected.account.information, err);
                    }
                }
            );
        }
    }

    private void update_command_actions() {
        Gtk.Widget? focus = get_focus();
        bool editing = (
            focus is Gtk.Text ||
            focus is Gtk.TextView ||
            focus is Composer.WebView
        );
        AccountContext? undo = get_command_context(true);
        get_edit_action(Action.Edit.UNDO).set_enabled(
            !editing && undo != null && undo.commands.can_undo
        );
        AccountContext? redo = get_command_context(false);
        get_edit_action(Action.Edit.REDO).set_enabled(
            !editing && redo != null && redo.commands.can_redo
        );
    }

    /** Finds the account whose next undo or redo is the newest command. */
    private AccountContext? get_command_context(bool undo) {
        if (!this.all_inboxes) {
            return get_selected_account_context();
        }
        var contexts = this.controller.get_account_contexts();
        for (int i = this.command_history.size - 1; i >= 0; i--) {
            foreach (var context in contexts) {
                Command? next = (
                    undo
                    ? context.commands.peek_undo()
                    : context.commands.peek_redo()
                );
                if (next == this.command_history[i]) {
                    return context;
                }
            }
        }
        return null;
    }

    private void record_command(Command command) {
        this.command_history.remove(command);
        this.command_history.add(command);
        if (this.command_history.size > MAX_COMMAND_HISTORY) {
            this.command_history.poll_head();
        }
    }

    private async bool prompt_delete_conversations(int count) {
        var dialog = new Adw.AlertDialog(
            /// Translators: Primary text for a confirmation dialog
            ngettext(
                "Do you want to permanently delete this conversation?",
                "Do you want to permanently delete these conversations?",
                count
            ),
            null
        );
        dialog.add_response("cancel", _("_Cancel"));
        dialog.add_response("delete", _("_Delete"));
        dialog.default_response = "delete";
        dialog.close_response = "cancel";
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        string response = yield dialog.choose(this, null);
        return (response == "delete");
    }

    private async bool prompt_delete_messages(int count) {
        var dialog = new Adw.AlertDialog(
            /// Translators: Primary text for a confirmation dialog
            ngettext(
                "Do you want to permanently delete this message?",
                "Do you want to permanently delete these messages?",
                count
            ),
            null
        );
        dialog.add_response("cancel", _("_Cancel"));
        dialog.add_response("delete", _("_Delete"));
        dialog.default_response = "delete";
        dialog.close_response = "cancel";
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        string response = yield dialog.choose(this, null);
        return (response == "delete");
    }

    private async Gee.Collection<Convey.App.Conversation>
        load_conversations_for_email(
            Convey.Folder location,
            Gee.Collection<Convey.EmailIdentifier> to_load) {
        bool was_loaded = false;
        // Can't assume the conversation monitor is valid, so check
        // it first.
        if (this.conversations != null &&
            this.conversations.base_folder == location) {
            try {
                yield this.conversations.load_email(to_load, this.folder_open);
                was_loaded = true;
            } catch (GLib.Error err) {
                debug("Error loading conversations to show them: %s",
                      err.message);
            }
        }

        // Conversation monitor may have changed since resuming from
        // the last async statement, so check it's still valid again.
        var loaded = new Gee.HashSet<Convey.App.Conversation>();
        if (was_loaded &&
            this.conversations != null &&
            this.conversations.base_folder == location) {
            foreach (var id in to_load) {
                Convey.App.Conversation? conversation =
                    this.conversations.get_by_email_identifier(id);
                if (conversation != null) {
                    loaded.add(conversation);
                }
            }
        }
        return loaded;
    }

    private inline void handle_error(Convey.AccountInformation? account,
                                     GLib.Error error) {
        Convey.ProblemReport? report = (account != null)
            ? new Convey.AccountProblemReport(account, error)
            : new Convey.ProblemReport(error);
        this.controller.report_problem(report);
    }

    private void update_ui() {
        // Only update if we haven't done so within the last while
        int64 now = GLib.get_monotonic_time() / (1000 * 1000);
        if (this.update_ui_last + UPDATE_UI_INTERVAL < now) {
            this.update_ui_last = now;

            if (this.conversation_viewer.current_list != null) {
                this.conversation_viewer.current_list.update_display();
            }

            this.conversation_list_view.refresh_times();
        }
    }

    private void select_account(Convey.Account? account) {
        if (this.selected_account != account) {
            this.selected_account = account;
            this.search_bar.set_account(account);

            if (account != null) {
                this.conversation_list_actions.account = account;
                this.conversation_viewer_actions.account = account;
                this.conversation_viewer.headerbar.left_actions.account = account;
                this.conversation_viewer.headerbar.right_actions.account = account;
            }

            update_command_actions();
        }
    }

    private async void select_conversations(Gee.Collection<Convey.App.Conversation> to_select,
                                            Gee.Collection<Convey.EmailIdentifier> scroll_to,
                                            bool is_interactive) {
        bool start_mark_timer = (
            is_interactive || this.previous_selection_was_interactive
        );
        this.previous_selection_was_interactive = is_interactive;

        // Ensure that the conversations are selected in the UI if
        // this was called by something other than the selection
        // changed callback. That will check to ensure that we're not
        // setting it again.
        this.conversation_list_view.select_conversations(to_select);

        this.conversation_list_actions.selected_conversations = to_select.size;
        this.conversation_viewer.headerbar.right_actions.selected_conversations = to_select.size;
        this.conversation_viewer.headerbar.left_actions.selected_conversations = to_select.size;

        if ((this.selected_folder != null || this.all_inboxes) &&
            !this.has_composer) {
            switch(to_select.size) {
            case 0:
                update_conversation_actions(NONE);
                if (current_conversation_count() > 0) {
                    this.conversation_viewer.show_none_selected();
                }
                break;

            case 1:
                update_conversation_actions(SINGLE);
                Convey.App.Conversation? convo = Convey.Collection.first(to_select);

                // It's possible for a conversation with zero email to
                // be selected, when it has just evaporated after its
                // last email was removed but the conversation monitor
                // hasn't signalled its removal yet. In this case,
                // just don't load it since it will soon disappear.
                if (this.all_inboxes && convo != null) {
                    select_account(convo.base_folder.account);
                }
                AccountContext? context = (
                    (this.all_inboxes && convo != null)
                    ? this.controller.get_context_for_account(
                        convo.base_folder.account.information
                    )
                    : get_selected_account_context()
                );
                if (context != null && convo.get_count() > 0) {
                    try {
                        yield this.conversation_viewer.load_conversation(
                            convo,
                            scroll_to,
                            context.emails,
                            context.contacts,
                            start_mark_timer
                        );
                    } catch (Convey.EngineError.NOT_FOUND err) {
                        // The first interesting email from the
                        // conversation wasn't found.
                        // This happens:
                        // - in the drafts folder, there is a race between the
                        // composer being discarded and the draft
                        // itself disappearing
                        // - when message has been removed while being loaded
                        debug("Ignoring not found error: %s", err.message);
                    } catch (GLib.IOError.CANCELLED err) {
                        // All good
                    } catch (GLib.Error err) {
                        handle_error(convo.base_folder.account.information, err);
                    }
                }
                break;

            default:
                update_conversation_actions(MULTIPLE);
                this.conversation_viewer.show_multiple_selected();
                break;
            }
        }
    }

    private async void open_conversation_monitor(Convey.App.ConversationMonitor to_open,
                                                 GLib.Cancellable cancellable) {
        to_open.scan_completed.connect(on_scan_completed);
        to_open.scan_error.connect(on_scan_error);

        to_open.scan_completed.connect(on_conversation_count_changed);
        to_open.conversations_added.connect(on_conversation_count_changed);
        to_open.conversations_removed.connect(on_conversation_count_changed);

        to_open.start_monitoring.begin(
            NO_DELAY,
            cancellable,
            (obj, res) => {
                try {
                    to_open.start_monitoring.end(res);
                } catch (GLib.Error err) {
                    handle_error(to_open.base_folder.account.information, err);
                }
            }
        );
    }

    private void close_conversation_monitor(Convey.App.ConversationMonitor to_close) {
        to_close.scan_completed.disconnect(on_scan_completed);
        to_close.scan_error.disconnect(on_scan_error);

        to_close.scan_completed.disconnect(on_conversation_count_changed);
        to_close.conversations_added.disconnect(on_conversation_count_changed);
        to_close.conversations_removed.disconnect(on_conversation_count_changed);

        to_close.stop_monitoring.begin(
            null,
            (obj, res) => {
                try {
                    to_close.stop_monitoring.end(res);
                } catch (GLib.Error err) {
                    warning(
                        "Error closing conversation monitor %s: %s",
                        to_close.base_folder.to_string(),
                        err.message
                    );
                }
            }
        );
    }

    private async void create_composer(Convey.Account send_context,
                                       Composer.Widget.ContextType type,
                                       Convey.Email context,
                                       string? quote) {
        var composer = yield this.controller.compose_with_context(
            this.controller.get_context_for_account(send_context.information),
            type,
            context,
            quote ?? ""
        );
        this.controller.present_composer(composer);
    }

    private async void create_composer_from_viewer(Composer.Widget.ContextType type) {
        Convey.Account? account = this.selected_account;
        ConversationEmail? email_view = null;
        ConversationListBox? list_view = this.conversation_viewer.current_list;
        if (list_view != null) {
            email_view = list_view.get_reply_target();
        }
        if (account != null && email_view != null) {
            string? quote = yield email_view.get_selection_for_quoting();
            yield create_composer(account, type, email_view.email, quote);
        }
    }

    /** Shows the spinner in place of the refresh button while busy. */
    private void headerbar_push_busy() {
        this.headerbar_busy_count++;
        this.refresh_stack.visible_child = this.headerbar_spinner;
    }

    /** Restores the refresh icon once all busy work has finished. */
    private void headerbar_pop_busy() {
        this.headerbar_busy_count = int.max(0, this.headerbar_busy_count - 1);
        if (this.headerbar_busy_count == 0) {
            this.refresh_stack.visible_child = this.refresh_image;
        }
    }

    private void on_refresh_folder() {
        bool any_offline = false;
        foreach (var folder in this.selected_folders) {
            Convey.ClientService incoming = folder.account.incoming;
            if (incoming.current_status == UNREACHABLE) {
                any_offline = true;
                continue;
            }

            var cancellable = new GLib.Cancellable();
            ulong status_id = incoming.notify["current-status"].connect(() => {
                if (incoming.current_status == UNREACHABLE) {
                    cancellable.cancel();
                }
            });

            headerbar_push_busy();
            folder.synchronise_remote.begin(cancellable, (obj, res) => {
                try {
                    folder.synchronise_remote.end(res);
                } catch (GLib.IOError.CANCELLED err) {
                    add_offline_toast();
                } catch (GLib.Error err) {
                    debug("Error refreshing %s: %s",
                        folder.path.to_string(), err.message);
                }
                incoming.disconnect(status_id);
                headerbar_pop_busy();
            });
        }
        if (any_offline) {
            add_offline_toast();
        }
    }

    private void add_offline_toast() {
        if (this.offline_toast != null) {
            return;
        }
        this.offline_toast = new Adw.Toast(
            // Translators: Toast shown when checking for new mail
            // while the mail server cannot be reached.
            _("Can’t check for new mail while offline")
        );
        this.offline_toast.dismissed.connect(() => this.offline_toast = null);
        add_toast(this.offline_toast);
    }

    private void on_conversations_selected(Gee.Set<Convey.App.Conversation> selected) {
        // The conversation viewer is shown next to the list unless the
        // inner split view is collapsed, in which case it is a separate
        // page reached by activating a row. Only defer loading to
        // activation when the viewer is actually a separate page --
        // keying off outer_view (the folder list) here would wrongly
        // defer at intermediate widths where the viewer is visible.
        bool viewer_is_separate_page = this.inner_view.collapsed;
        bool folded = this.outer_view.collapsed;

        // If the viewer is a separate page, selection is handled by activate
        if (selected.size > 1 || !viewer_is_separate_page) {
            select_conversations.begin(
                selected,
                Gee.Collection.empty(),
                !this.conversation_list_view.is_autoselecting
            );
        } else if (viewer_is_separate_page) {
            switch(selected.size) {
            case 0:
                update_conversation_actions(NONE);
                break;
            case 1:
                update_conversation_actions(SINGLE);
                break;
            default:
                update_conversation_actions(MULTIPLE);
                break;
            }
        }

        if (this.conversation_list_view.selection_mode_enabled) {
            if (selected.size > 0) {
                this.conversation_list_actions_revealer.reveal_child = folded;
            } else {
                this.conversation_list_actions_revealer.reveal_child = false;
            }
        }
    }

    private void on_conversation_activated(Convey.App.Conversation activated, uint button) {
        if (button == Gdk.BUTTON_PRIMARY) {
            bool collapsed = this.inner_view.collapsed;
            this.outer_view.show_content = true;
            if (collapsed) {
                Gee.Collection<Convey.App.Conversation> selected =
                    new Gee.ArrayList<Convey.App.Conversation>();
                selected.add(activated);
                select_conversations.begin(selected, Gee.Collection.empty(), true);
            } else if (this.conversation_viewer.current_list?.conversation == activated) {
                this.previous_selection_was_interactive = true;
                this.conversation_viewer.current_list.mark_visible_read_on_activate();
            }
        } else if (this.selected_folder != null) {
            if (this.selected_folder.used_as != DRAFTS) {
                this.application.new_window.begin(
                    this.selected_folder,
                    this.conversation_list_view.selected
                    );
            } else {
                // TODO: Determine how to map between conversations
                // and drafts correctly.
                Convey.Email draft = activated.get_latest_recv_email(IN_FOLDER);
                this.create_composer.begin(
                    this.selected_folder.account,
                    EDIT,
                    draft,
                    null
                );
            }
        }
    }

    private void on_conversation_count_changed() {
        // Only update the UI if we don't currently have a composer,
        // so we don't clobber it
        if (!this.has_composer) {
            if (current_conversation_count() == 0) {
                // Let the user know if there's no available conversations
                if (this.selected_folder != null &&
                    this.selected_folder.used_as == SEARCH) {
                    this.conversation_viewer.show_empty_search();
                } else {
                    this.conversation_viewer.show_empty_folder();
                }
                update_conversation_actions(NONE);
            } else {
                // When not doing autoselect, we never get
                // conversations_selected firing from the convo list,
                // so we need to stop the loading spinner here.
                if (!this.application.config.autoselect &&
                    this.conversation_list_view.selected.size == 0) {
                    this.conversation_viewer.show_none_selected();
                    update_conversation_actions(NONE);
                }
            }
        }
    }

    private int current_conversation_count() {
        int count = 0;
        if (this.conversations != null) {
            count = this.conversations.size;
        }
        foreach (var monitor in this.inbox_monitors) {
            count += monitor.size;
        }
        return count;
    }

    private void update_headerbar() {
        update_title();
        // Note the headerbar no longer shows the folder's unread
        // count: since the GTK4 port the subtitle holds the account
        // address, and the folder list already shows the count
    }

    private void update_conversation_actions(ConversationCount count) {
        bool sensitive = (count != NONE);
        bool multiple = (count == MULTIPLE);

        bool find_in_enabled = (
            sensitive && !multiple && this.is_conversation_viewer_shown
        );
        get_window_action(ACTION_FIND_IN_CONVERSATION).set_enabled(find_in_enabled);
        this.conversation_viewer.headerbar.set_find_sensitive(find_in_enabled);

        Convey.Folder? actions_on = this.folder_for_actions;
        bool reply_sensitive = (
            sensitive &&
            !multiple &&
            actions_on != null &&
            actions_on.used_as != DRAFTS
        );
        get_window_action(ACTION_REPLY_CONVERSATION).set_enabled(reply_sensitive);
        get_window_action(ACTION_REPLY_ALL_CONVERSATION).set_enabled(reply_sensitive);
        get_window_action(ACTION_REPLY_LIST_CONVERSATION).set_enabled(reply_sensitive);
        get_window_action(ACTION_FORWARD_CONVERSATION).set_enabled(reply_sensitive);

        bool copy_enabled = (
            sensitive &&
            (this.selected_folder != null ||
             selected_groups().get_keys().size == 1) &&
            (actions_on is Convey.FolderSupport.Copy)
        );
        if (this.all_inboxes && actions_on != null) {
            foreach (var actions in this.folder_conversation_actions) {
                if (actions.account != actions_on.account) {
                    actions.account = actions_on.account;
                }
                if (actions.source_folder != actions_on) {
                    actions.source_folder = actions_on;
                }
            }
        }
        get_window_action(ACTION_SHOW_COPY_MENU).set_enabled(copy_enabled);
        foreach (var actions in this.folder_conversation_actions) {
            actions.set_copy_sensitive(copy_enabled);
        }

        bool mark_enabled = (
            sensitive && (actions_on is Convey.FolderSupport.Mark)
        );
        foreach (var actions in this.folder_conversation_actions) {
            actions.set_mark_sensitive(mark_enabled);
        }

        get_window_action(ACTION_ARCHIVE_CONVERSATION).set_enabled(
            sensitive && (actions_on is Convey.FolderSupport.Archive)
        );
        get_window_action(ACTION_TRASH_CONVERSATION).set_enabled(
            sensitive && this.selected_folder_supports_trash
        );
        get_window_action(ACTION_TRASH_OR_ARCHIVE_CONVERSATION).set_enabled(
            sensitive && (
                this.selected_folder_supports_trash ||
                actions_on is Convey.FolderSupport.Archive
            )
        );
        get_window_action(ACTION_DELETE_CONVERSATION).set_enabled(
            sensitive && (actions_on is Convey.FolderSupport.Remove)
        );

        this.update_context_dependent_actions.begin(sensitive);
        update_trash_action();
    }

    private static bool archives_instead_of_trash(Convey.Folder folder) {
        return (
            folder.account.information.archive_instead_of_trash &&
            folder is Convey.FolderSupport.Archive
        );
    }

    private void update_trash_action() {
        bool trash_supported = this.selected_folder_supports_trash;
        Gee.Collection<Convey.Folder> folders = selected_groups().get_keys();
        if (folders.is_empty) {
            folders = this.selected_folders;
        }
        int archiving = 0;
        foreach (var folder in folders) {
            if (archives_instead_of_trash(folder)) {
                archiving++;
            }
        }

        var mode = Components.ConversationActions.RemoveMode.TRASH;
        if (this.is_shift_down) {
            mode = DELETE;
        } else if (archiving > 0 && archiving == folders.size) {
            mode = ARCHIVE;
        } else if (archiving > 0) {
            mode = MIXED;
        } else if (!trash_supported) {
            mode = DELETE;
        }
        this.conversation_list_actions.update_trash_button(mode, trash_supported);
        this.conversation_viewer.headerbar.left_actions.update_trash_button(mode, trash_supported);
        this.conversation_viewer.headerbar.right_actions.update_trash_button(mode, trash_supported);
    }

    private async void update_context_dependent_actions(bool sensitive) {
        // Cancel any existing update that is running
        this.action_update_cancellable.cancel();
        GLib.Cancellable cancellable = new Cancellable();
        this.action_update_cancellable = cancellable;

        Gee.MultiMap<Convey.EmailIdentifier, Type>? selected_operations = null;
        if (this.selected_folder != null) {
            AccountContext? context =
                this.controller.get_context_for_account(
                    this.selected_folder.account.information
                );
            if (context != null) {
                Gee.Collection<Convey.EmailIdentifier> ids =
                    new Gee.LinkedList<Convey.EmailIdentifier>();
                foreach (Convey.App.Conversation convo in
                         this.conversation_list_view.selected) {
                    ids.add_all(convo.get_email_ids());
                }
                try {
                    selected_operations = yield context.emails.get_supported_operations_async(
                        ids, cancellable
                    );
                } catch (GLib.Error e) {
                    debug("Error checking for what operations are supported in the selected conversations: %s",
                          e.message);
                }
            }
        }

        if (!cancellable.is_cancelled()) {
            Gee.HashSet<Type> supported_operations = new Gee.HashSet<Type>();
            if (selected_operations != null) {
                supported_operations.add_all(selected_operations.get_values());
            }

            get_window_action(ACTION_SHOW_COPY_MENU).set_enabled(
                sensitive &&
                (supported_operations.contains(typeof(Convey.FolderSupport.Copy)))
            );
        }
    }

    private void set_shift_key_down(bool down) {
        this.is_shift_down = down;
        update_trash_action();
    }

    private inline void check_shift_event(uint keyval, bool is_key_press) {
        // FIXME: it's possible the user will press two shift keys.  We want
        // the shift key to report as released when they release ALL of them.
        // There doesn't seem to be an easy way to do this in Gdk.
        if (keyval == Gdk.Key.Shift_L || keyval == Gdk.Key.Shift_R) {
            Gtk.Widget? focus = get_focus();
            if (focus == null ||
                (!(focus is Gtk.Entry) && !(focus is Composer.WebView))) {
                set_shift_key_down(is_key_press);
            }
        }
    }

    // Panes are plain containers, so grab_focus() alone won't take on
    // most of them -- fall back to handing focus to something inside.
    private bool focus_pane(Gtk.Widget pane) {
        return (
            pane.grab_focus() ||
            pane.child_focus(Gtk.DirectionType.TAB_FORWARD)
        );
    }

    // Makes Left/Right in pane move the focus to the neighbouring pane.
    // Runs in the capture phase since the panes' list widgets consume the
    // horizontal arrow keys themselves.
    private void setup_pane_navigation(Gtk.Widget pane,
                                       Gtk.Widget? left,
                                       Gtk.Widget? right) {
        var keys = new Gtk.EventControllerKey() {
            propagation_phase = Gtk.PropagationPhase.CAPTURE
        };
        keys.key_pressed.connect((keyval, keycode, state) => {
            if ((state & (Gdk.ModifierType.CONTROL_MASK |
                          Gdk.ModifierType.ALT_MASK |
                          Gdk.ModifierType.SHIFT_MASK)) != 0) {
                return false;
            }
            // Don't steal cursor keys from an entry (e.g. renaming a
            // folder in place, or the search bar).
            if (get_focus() is Gtk.Editable) {
                return false;
            }

            Gtk.Widget? target = null;
            switch (keyval) {
            case Gdk.Key.Left:
            case Gdk.Key.KP_Left:
                target = left;
                break;
            case Gdk.Key.Right:
            case Gdk.Key.KP_Right:
                target = right;
                break;
            default:
                return false;
            }

            return (target != null) ? focus_pane(target) : false;
        });
        pane.add_controller(keys);
    }

    private new void focus_widget(Gtk.Widget? widget) {
        if (widget != null) {
            widget.focus(TAB_FORWARD);
        } else {
            error_bell();
        }
    }

    private SimpleAction get_window_action(string name) {
        return (SimpleAction) lookup_action(name);
    }

    private SimpleAction get_edit_action(string name) {
        return (SimpleAction) this.edit_actions.lookup_action(name);
    }

    private new void activate_action(GLib.Action? action) {
        if (action != null && action.get_enabled()) {
            action.activate(null);
        } else {
            error_bell();
        }
    }

    private void reply_conversation(Composer.Widget.ContextType context_type) {
        if (this.inner_view.collapsed) {
            this.conversation_list_view.activate_selected();
            close_folder_drawer();
            // This is a lot of async actions, delay composer creation
            GLib.Timeout.add(500, () => {
              this.create_composer_from_viewer.begin(context_type);
              return Source.REMOVE;
            });
        } else {
            this.create_composer_from_viewer.begin(context_type);
        }
    }

    private void on_scan_completed(Convey.App.ConversationMonitor monitor) {
        // Done scanning.  Check if we have enough messages to fill
        // the conversation list; if not, trigger a load_more();
        Gtk.Scrollbar? scrollbar = (
            this.conversation_list_view.scrolled_window.get_vscrollbar() as Gtk.Scrollbar
        );
        if (is_visible() &&
            (scrollbar == null || !scrollbar.get_visible()) &&
            monitor == this.conversations &&
            monitor.can_load_more) {
            debug("Not enough messages, loading more for folder %s",
                  this.selected_folder.to_string());
            this.conversation_list_view.load_more(MIN_CONVERSATION_COUNT);
        }
    }

    private void on_scan_error(Convey.App.ConversationMonitor monitor,
                               GLib.Error err) {
        Convey.AccountInformation account =
            monitor.base_folder.account.information;
        this.controller.report_problem(
            new Convey.ServiceProblemReport(account, account.incoming, err)
        );
    }

    [GtkCallback]
    private void on_map() {
        this.update_ui_timeout.start();
        update_ui();
    }

    [GtkCallback]
    private void on_unmap() {
        // Save window size here as well as in close_request, since
        // application quit tears windows down without a close request
        this.window_width = this.default_width;
        this.window_height = this.default_height;
        this.update_ui_timeout.reset();
    }

    [GtkCallback]
    private void on_focus_enter(Gtk.EventControllerFocus controller) {
        set_shift_key_down(false);
        application.controller.window_focus_in();
    }

    [GtkCallback]
    private void on_focus_leave(Gtk.EventControllerFocus controller) {
        set_shift_key_down(false);
        application.controller.window_focus_out();
    }

    private void update_empty_message() {
        Adw.StatusPage? page = this.conversation_viewer.empty_page;
        bool list_shown =
            (!this.outer_view.collapsed || !this.outer_view.show_content) &&
            (!this.inner_view.collapsed || !this.inner_view.show_sidebar);
        bool overlay = page != null && list_shown;
        this.empty_overlay_page.visible = overlay;
        if (page != null) {
            page.opacity = overlay ? 0 : 1;
            this.empty_overlay_page.icon_name = page.icon_name;
            this.empty_overlay_page.title = page.title;
            this.empty_overlay_page.description = page.description;
        }
    }

    private bool on_empty_overlay_position(Gtk.Overlay overlay,
                                           Gtk.Widget widget,
                                           out Gdk.Rectangle allocation) {
        allocation = Gdk.Rectangle();
        Graphene.Rect list;
        if (!this.conversation_list_view.compute_bounds(overlay, out list)) {
            return false;
        }
        float right = this.outer_view.collapsed
            ? list.origin.x + list.size.width
            : overlay.get_width();
        allocation = { (int) list.origin.x, (int) list.origin.y,
                       (int) (right - list.origin.x), (int) list.size.height };
        return true;
    }

    [GtkCallback]
    private void on_outer_view_changed(GLib.Object object, ParamSpec pspec) {
        this.sidebar_resize_handle.visible = !this.outer_view.collapsed;
        update_empty_message();
        bool shown = this.is_conversation_viewer_shown;
        this.conversation_list_view.can_autoselect = shown;
        if (!shown && !this.conversation_list_view.selection_mode_enabled) {
            this.conversation_list_view.unselect_all();
        }
    }

    private void on_sidebar_drag_begin(Gtk.GestureDrag gesture,
                                       double x, double y) {
        this.sidebar_dragged = false;
        Graphene.Rect bounds;
        if (!this.sidebar_resize_handle.compute_bounds(this.outer_view, out bounds) ||
            !bounds.contains_point(Graphene.Point() { x = (float) x, y = (float) y })) {
            gesture.set_state(DENIED);
            return;
        }
        this.sidebar_drag_start_width = bounds.origin.x;
    }

    private void on_sidebar_drag_update(Gtk.GestureDrag gesture,
                                        double dx, double dy) {
        if (gesture.get_sequence_state(gesture.get_current_sequence()) !=
            Gtk.EventSequenceState.CLAIMED) {
            if (dx.abs() < 3) {
                return;
            }
            gesture.set_state(CLAIMED);
        }
        int total = this.outer_view.get_width();
        double width = (this.sidebar_drag_start_width + dx).clamp(360, total - 360);
        this.outer_view.min_sidebar_width = 360;
        this.outer_view.max_sidebar_width = total;
        this.outer_view.sidebar_width_fraction = width / total;
        this.sidebar_dragged = true;
    }

    private void on_folder_drag_begin(Gtk.GestureDrag gesture,
                                      double x, double y) {
        this.folder_list_dragged = false;
        Graphene.Rect bounds;
        if (!this.folder_resize_handle.compute_bounds(this.inner_view, out bounds) ||
            !bounds.contains_point(Graphene.Point() { x = (float) x, y = (float) y })) {
            gesture.set_state(DENIED);
            return;
        }
        this.folder_drag_start_width = bounds.origin.x;
    }

    private void on_folder_drag_update(Gtk.GestureDrag gesture,
                                       double dx, double dy) {
        if (gesture.get_sequence_state(gesture.get_current_sequence()) !=
            Gtk.EventSequenceState.CLAIMED) {
            if (dx.abs() < 3) {
                return;
            }
            gesture.set_state(CLAIMED);
        }
        set_folder_list_width((int) (this.folder_drag_start_width + dx));
        this.folder_list_dragged = true;
    }

    private void set_folder_list_width(int width) {
        width = width.clamp(180, 400);
        this.inner_view.min_sidebar_width = 180;
        this.inner_view.max_sidebar_width = width;
        this.inner_view.sidebar_width_fraction = 1.0;
    }

    private void close_folder_drawer() {
        if (this.inner_view.collapsed) {
            this.inner_view.show_sidebar = false;
        }
    }

    [GtkCallback]
    private void on_inner_view_changed(GLib.Object object, ParamSpec pspec) {
        this.folder_resize_handle.visible = !this.inner_view.collapsed;
        update_empty_message();
        int selected = this.conversation_list_view.selected.size;
        update_conversation_actions(
            ConversationCount.for_size(selected)
        );
        if (this.inner_view.collapsed) {
            // Ensure something useful gets the keyboard focus, given
            // GNOME/libhandy#179
            if (this.is_conversation_list_shown) {
                this.conversation_list_view.grab_focus();
            } else if (this.is_folder_list_shown) {
                this.folder_list.grab_focus();
            }

            // Close any open composer that is no longer visible
            if (this.has_composer &&
                (this.is_folder_list_shown || this.is_conversation_list_shown)) {
                close_composer(false, false);
            }
        } else if (selected > 0) {
            var shown = this.conversation_viewer.current_list?.conversation;
            if (selected > 1 || shown == null ||
                !(shown in this.conversation_list_view.selected)) {
                select_conversations.begin(
                    this.conversation_list_view.selected,
                    Gee.Collection.empty<Convey.EmailIdentifier>(),
                    false
                );
            }
        }
    }

    private void on_offline_infobar_response() {
        this.info_bars.remove(this.offline_infobar);
    }

    private void on_service_problem_retry() {
        this.info_bars.remove(this.service_problem_infobar);
        this.service_problem_infobar = null;
        retry_service_problem(Convey.ClientService.Status.CONNECTION_FAILED);
    }

    private void on_cert_problem_retry() {
        this.info_bars.remove(this.cert_problem_infobar);
        retry_service_problem(Convey.ClientService.Status.TLS_VALIDATION_FAILED);
    }

    private void on_auth_problem_retry() {
        this.info_bars.remove(this.auth_problem_infobar);
        retry_service_problem(Convey.ClientService.Status.AUTHENTICATION_FAILED);
    }

    private void on_update_ui_timeout() {
        update_ui();
    }

    private void on_account_available(AccountContext account) {
        add_account(account);
    }

    private void on_account_unavailable(AccountContext account,
                                        bool is_shutdown) {
        // If we're not shutting down, select the inbox of the first
        // account so that we show something other than empty
        // conversation list/viewer.
        Convey.Folder? to_select = null;
        if (!is_shutdown) {
            to_select = get_first_inbox();
        }
        this.remove_account.begin(account, to_select);
    }

    private void on_folders_available(Gee.Collection<FolderContext> available) {
        add_folders(available);
    }

    private void on_folders_unavailable(Gee.Collection<FolderContext> unavailable) {
        remove_folders(unavailable, true);
    }

    private void on_use_changed(Convey.Folder folder,
                                Convey.Folder.SpecialUse old_type,
                                Convey.Folder.SpecialUse new_type) {
        // Update the main window
        AccountContext? context = this.controller.get_context_for_account(
            folder.account.information
        );
        if (context != null) {
            FolderContext? folder_context = context.get_folder(folder);
            if (folder_context != null) {
                this.folder_list.remove_folder(folder_context);
                this.folder_list.add_folder(folder_context);

                // Since removing the folder will also remove its children
                // from the folder list, we need to check for any and re-add
                // them. See issue #11.
                try {
                    foreach (Convey.Folder child in
                             folder.account.list_matching_folders(folder.path)) {
                        FolderContext? child_context = context.get_folder(child);
                        if (child_context != null) {
                            this.folder_list.add_folder(child_context);
                        }
                    }
                } catch (Error err) {
                    // Oh well
                }
            }
        }
    }

    private void on_command_execute(Command command) {
        record_command(command);
        if (!(command is TrivialCommand)) {
            // Only show an execute notification for non-trivial
            // commands
            on_command_redo(command);
        } else {
            // Still have to update the undo/redo actions for trivial
            // commands
            update_command_actions();
        }
    }

    private void on_command_undo(Command command) {
        record_command(command);
        update_command_actions();
        EmailCommand? email = command as EmailCommand;
        if (email != null && !this.all_inboxes) {
            if (email.conversations.size > 1) {
                this.show_conversations.begin(
                    email.location, email.conversations, false
                );
            } else {
                this.show_email.begin(
                    email.location, email.email, false
                );
            }
        }
        if (command.undone_label != null) {
            var toast = new Adw.Toast(command.undone_label);
            toast.button_label = _("Redo");
            toast.action_name = Action.Edit.prefix(Action.Edit.REDO);
            add_toast(toast);
        }
    }

    private void on_command_redo(Command command) {
        record_command(command);
        update_command_actions();
        if (command.executed_label != null) {
            var toast = new Adw.Toast(command.executed_label);
            toast.button_label = _("Undo");
            toast.action_name = Action.Edit.prefix(Action.Edit.UNDO);
            if (command.executed_notification_brief)
                toast.timeout = application.config.brief_notification_duration;
            add_toast(toast);
        }
    }

    private void on_conversation_view_added(ConversationListBox list) {
        list.notify["latest-has-list-post"].connect(on_latest_has_list_post);
        list.email_loaded.connect(on_email_loaded);
        list.mark_email.connect(on_email_mark);
        list.reply_to_all_email.connect(on_email_reply_to_all);
        list.reply_to_list_email.connect(on_email_reply_to_list);
        list.reply_to_sender_email.connect(on_email_reply_to_sender);
        list.forward_email.connect(on_email_forward);
        list.unsubscribe_email.connect(on_email_unsubscribe);
        list.trash_email.connect(on_email_trash);
        list.delete_email.connect(on_email_delete);
    }

    // Window-level action callbacks

    private void on_undo() {
        this.undo.begin();
    }

    private void on_redo() {
        this.redo.begin();
    }

    private void on_close() {
        close();
    }

    // this signal does not necessarily indicate that the application
    // previously didn't have focus and now it does
    private void on_has_toplevel_focus() {
        clear_new_messages();
    }

    private void clear_new_messages() {
        var visible = this.conversation_list_view.visible_conversations;
        foreach (var folder in this.selected_folders) {
            this.controller.clear_new_messages(folder, visible);
        }
    }

    private void on_folder_expansion_changed() {
        this.application.config.set_collapsed_folder_groups(
            this.folder_list.get_collapsed()
        );
    }

    private void on_folder_selected(Convey.Folder? folder) {
        this.select_folder.begin(folder, true);
    }

    private void on_all_inboxes_selected() {
        this.select_all_inboxes.begin(true);
    }

    private void on_all_inboxes_activated() {
        close_folder_drawer();
        if (this.application.config.autoselect) {
            focus_widget(this.conversation_viewer.get_visible_child());
        }
    }

    private void on_select_inbox(SimpleAction action, Variant? parameter) {
        if (parameter != null) {
            int account_number = parameter.get_int32();
            try {
                Gee.Collection<Convey.Account> accounts =
                    this.application.engine.get_accounts();
                if (account_number < accounts.size) {
                    Convey.Account account = accounts.to_array()[account_number];
                    Convey.Folder inbox = account.get_special_folder(INBOX);
                    this.select_folder.begin(inbox, true);
                }
            } catch (GLib.Error error) {
                debug("Error getting accounts");
            }
        }
    }

    private void on_search(string text) {
        if (Convey.String.is_empty_or_whitespace(text)) {
            stop_search(true);
        } else {
            this.start_search(text, true);
        }
    }

    private void on_visible_conversations_changed() {
        clear_new_messages();
    }

    private void on_folder_activated(Convey.Folder? folder) {
        if (folder != null) {
            close_folder_drawer();
            // Focus on conversation list will autoselect
            if (this.application.config.autoselect) {
                focus_widget(this.conversation_viewer.get_visible_child());
            }
        }
    }

    private void on_find_in_conversation_action() {
        this.conversation_viewer.enable_find();
    }

    private void on_search_activated() {
        show_search_bar();
    }

    private void on_zoom(SimpleAction action, Variant? parameter) {
        ConversationListBox? view = this.conversation_viewer.current_list;
        if (view != null && parameter != null) {
            string zoom_action = parameter.get_string();
            if (zoom_action == "in")
                view.zoom_in();
            else if (zoom_action == "out")
                view.zoom_out();
            else
                view.zoom_reset();
        }
    }

    private void on_reply_conversation() {
        reply_conversation(REPLY_SENDER);
    }

    private void on_reply_all_conversation() {
        reply_conversation(REPLY_ALL);
    }

    private void on_reply_list_conversation() {
        reply_conversation(REPLY_LIST);
    }

    private void on_latest_has_list_post(GLib.Object object,
                                         GLib.ParamSpec param) {
        var list = (ConversationListBox) object;
        if (list == this.conversation_viewer.current_list) {
            update_reply_list_button(list.latest_has_list_post);
        }
    }

    private void update_reply_list_button(bool show) {
        foreach (var actions in this.folder_conversation_actions) {
            actions.show_reply_list = show;
        }
    }

    private void on_forward_conversation() {
        reply_conversation(FORWARD);
    }

    private void on_show_window_menu() {
        show_window_menu();
    }

    private void on_show_help_overlay() {
        var overlay = get_help_overlay();
        overlay.section_name = "conversation";
        overlay.show();
    }

    private void on_show_copy_menu() {
        if (this.is_conversation_list_shown &&
            this.conversation_list_actions_revealer.child_revealed) {
            this.conversation_list_actions.show_copy_menu();
        } else if (this.is_conversation_viewer_shown) {
            this.conversation_viewer.headerbar.left_actions.show_copy_menu();
            this.conversation_viewer.headerbar.right_actions.show_copy_menu();
        } else {
            error_bell();
        }
    }

    private void on_conversation_up() {
        this.conversation_list_view.scroll(Gtk.ScrollType.STEP_UP);
    }

    private void on_conversation_down() {
        this.conversation_list_view.scroll(Gtk.ScrollType.STEP_DOWN);
    }

    private void on_show_mark_menu() {
        bool unread_selected = false;
        bool read_selected = false;
        bool starred_selected = false;
        bool unstarred_selected = false;
        foreach (Convey.App.Conversation conversation in
                 this.conversation_list_view.selected) {
            if (conversation.is_unread())
                unread_selected = true;

            // Only check the messages that "Mark as Unread" would mark, so we
            // don't add the menu option and have it not do anything.
            //
            // Sort by Date: field to correspond with ConversationViewer ordering
            Convey.Email? latest = conversation.get_latest_sent_email(
                Convey.App.Conversation.Location.IN_FOLDER_OUT_OF_FOLDER);
            if (latest != null && latest.email_flags != null
                && !latest.email_flags.contains(Convey.EmailFlags.UNREAD))
                read_selected = true;

            if (conversation.is_flagged()) {
                starred_selected = true;
            } else {
                unstarred_selected = true;
            }
        }
        get_window_action(ACTION_MARK_AS_READ).set_enabled(unread_selected);
        get_window_action(ACTION_MARK_AS_UNREAD).set_enabled(read_selected);
        get_window_action(ACTION_MARK_AS_STARRED).set_enabled(unstarred_selected);
        get_window_action(ACTION_MARK_AS_UNSTARRED).set_enabled(starred_selected);

        // If we're in Drafts/Outbox, we also shouldn't set a message as junk
        Convey.Folder? actions_on = this.folder_for_actions;
        get_window_action(ACTION_TOGGLE_JUNK).set_enabled(
            actions_on != null &&
            actions_on.used_as != JUNK &&
            actions_on.used_as != DRAFTS &&
            actions_on.used_as != OUTBOX
        );
    }

    private void on_mark_conversations(Gee.Collection<Convey.App.Conversation> conversations,
                                       Convey.NamedFlag flag) {
        mark_conversations(conversations, flag, true);
    }

    private void mark_conversations(Gee.Collection<Convey.App.Conversation> conversations,
                                    Convey.NamedFlag flag,
                                    bool to_add) {
        var groups = group_by_folder(conversations);
        foreach (var location in groups.get_keys()) {
            this.controller.mark_conversations.begin(
                location,
                groups.get(location),
                flag,
                to_add,
                (obj, res) => {
                    try {
                        this.controller.mark_conversations.end(res);
                    } catch (GLib.Error err) {
                        handle_error(location.account.information, err);
                    }
                }
            );
        }
    }

    private void on_mark_as_read() {
        mark_conversations(
            this.conversation_list_view.selected, Convey.EmailFlags.UNREAD, false
        );
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_mark_as_unread() {
        mark_conversations(
            this.conversation_list_view.selected, Convey.EmailFlags.UNREAD, true
        );
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_mark_as_starred() {
        mark_conversations(
            this.conversation_list_view.selected, Convey.EmailFlags.FLAGGED, true
        );
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_mark_as_unstarred() {
        mark_conversations(
            this.conversation_list_view.selected, Convey.EmailFlags.FLAGGED, false
        );
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_mark_as_junk_toggle() {
        var groups = selected_groups();
        unselect_unless_autoselect();
        foreach (var source in groups.get_keys()) {
            Convey.Folder.SpecialUse destination =
                (source.used_as != JUNK)
                ? Convey.Folder.SpecialUse.JUNK
                : Convey.Folder.SpecialUse.INBOX;
            move_conversations_special(
                source, destination, groups.get(source)
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void move_conversations_special(
        Convey.Folder source,
        Convey.Folder.SpecialUse destination,
        Gee.Collection<Convey.App.Conversation> conversations) {
        this.controller.move_conversations_special.begin(
            source,
            destination,
            conversations,
            (obj, res) => {
                try {
                    this.controller.move_conversations_special.end(res);
                } catch (GLib.Error err) {
                    handle_error(source.account.information, err);
                }
            }
        );
    }

    private void on_mail_drag_active(bool active) {
        var sources = new Gee.HashSet<Convey.Folder>();
        if (active) {
            sources.add_all(
                selected_groups().get_keys()
            );
        }
        this.folder_list.set_drag_sources(sources);
        this.folder_list.set_drag_active(active);
    }

    private void update_header_divider() {
        var list = this.conversation_list_view.scrolled_window.vadjustment;
        var viewer = this.conversation_viewer.conversation_scroller.vadjustment;
        if (list.value > list.lower || viewer.value > viewer.lower) {
            this.outer_view.add_css_class("scrolled-under");
        } else {
            this.outer_view.remove_css_class("scrolled-under");
        }
        if (viewer.value > viewer.lower) {
            this.outer_view.add_css_class("viewer-scrolled-under");
        } else {
            this.outer_view.remove_css_class("viewer-scrolled-under");
        }
    }

    private void on_move_conversation(Convey.Folder destination) {
        var groups = selected_groups();
        unselect_unless_autoselect();
        foreach (var location in groups.get_keys()) {
            var source = location as Convey.FolderSupport.Move;
            if (source == null || location.account != destination.account) {
                continue;
            }
            this.controller.move_conversations.begin(
                source,
                destination,
                groups.get(location),
                (obj, res) => {
                    try {
                        this.controller.move_conversations.end(res);
                    } catch (GLib.Error err) {
                        handle_error(location.account.information, err);
                    }
                }
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_copy_conversation(Convey.Folder destination) {
        var groups = selected_groups();
        foreach (var location in groups.get_keys()) {
            var source = location as Convey.FolderSupport.Copy;
            if (source == null || location.account != destination.account) {
                continue;
            }
            this.controller.copy_conversations.begin(
                source,
                destination,
                groups.get(location),
                (obj, res) => {
                    try {
                        this.controller.copy_conversations.end(res);
                    } catch (GLib.Error err) {
                        handle_error(location.account.information, err);
                    }
                }
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void move_selected_special(Convey.Folder.SpecialUse destination) {
        var groups = selected_groups();
        unselect_unless_autoselect();
        foreach (var source in groups.get_keys()) {
            move_conversations_special(source, destination, groups.get(source));
        }
    }

    private void unselect_unless_autoselect() {
        if (!this.application.config.autoselect) {
            this.conversation_list_view.unselect_all();
        }
    }

    private void on_archive_conversation() {
        move_selected_special(ARCHIVE);
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_trash_conversation() {
        move_selected_special(TRASH);
        // No need to disable selection mode, handled by model change
    }

    private void on_trash_or_archive_conversation() {
        var groups = selected_groups();
        unselect_unless_autoselect();
        foreach (var source in groups.get_keys()) {
            if (archives_instead_of_trash(source)) {
                move_conversations_special(source, ARCHIVE, groups.get(source));
            } else if (Controller.does_folder_support_trash(source)) {
                move_conversations_special(source, TRASH, groups.get(source));
            }
        }
    }

    private void on_delete_conversation() {
        do_delete_conversation.begin();
    }

    private async void do_delete_conversation() {
        var groups = selected_groups();
        if (groups.size == 0 ||
            !yield prompt_delete_conversations(groups.size))
            return;

        unselect_unless_autoselect();
        foreach (var source in groups.get_keys()) {
            var target = source as Convey.FolderSupport.Remove;
            if (target == null)
                continue;

            try {
                yield this.controller.delete_conversations(
                    target,
                    groups.get(source));
            } catch (GLib.Error err) {
                handle_error(source.account.information, err);
            }
        }

        // No need to disable selection mode, handled by model change
    }

    private void on_email_loaded(ConversationListBox view,
                                 Convey.Email loaded) {
        this.controller.email_loaded(
            view.conversation.base_folder.account.information,
            loaded
        );

        string? subject = null;
        try {
            subject = loaded.get_message().protected_subject;
        } catch (GLib.Error err) {
            debug("Unable to read message subject: %s", err.message);
        }
        if (subject != null && loaded.message_id != null) {
            this.application.decrypted_subjects.set(loaded.message_id, subject);
            this.conversation_list_view.on_conversation_updated(view.conversation);
            this.conversation_viewer.update_subject();
        }
    }

    // The folder an action on a displayed conversation applies to
    private Convey.Folder? folder_for(ConversationListBox view) {
        return this.selected_folder ?? view.conversation.base_folder;
    }

    private void on_email_mark(ConversationListBox view,
                               Gee.Collection<Convey.EmailIdentifier> messages,
                               Convey.NamedFlag? to_add,
                               Convey.NamedFlag? to_remove) {
        Convey.Folder? location = folder_for(view);
        if (location != null) {
            Convey.EmailFlags add_flags = null;
            if (to_add != null) {
                add_flags = new Convey.EmailFlags();
                add_flags.add(to_add);
            }
            Convey.EmailFlags remove_flags = null;
            if (to_remove != null) {
                remove_flags = new Convey.EmailFlags();
                remove_flags.add(to_remove);
            }
            var ids = new Gee.HashSet<Convey.EmailIdentifier>();
            foreach (var id in messages) {
                ids.add_all(view.conversation.with_copies(id));
            }
            this.controller.mark_messages.begin(
                location,
                Convey.Collection.single(view.conversation),
                ids,
                add_flags,
                remove_flags,
                (obj, res) => {
                    try {
                        this.controller.mark_messages.end(res);
                    } catch (GLib.Error err) {
                        handle_error(location.account.information, err);
                    }
                }
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_email_reply_to_sender(Convey.Email target, string? quote) {
        if (this.selected_account != null) {
            this.create_composer.begin(
                this.selected_account, REPLY_SENDER, target, quote
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_email_reply_to_all(Convey.Email target, string? quote) {
        if (this.selected_account != null) {
            this.create_composer.begin(
                this.selected_account, REPLY_ALL, target, quote
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_email_reply_to_list(Convey.Email target, string? quote) {
        if (this.selected_account != null) {
            this.create_composer.begin(
                this.selected_account, REPLY_LIST, target, quote
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_email_forward(Convey.Email target, string? quote) {
        if (this.selected_account != null) {
            this.create_composer.begin(
                this.selected_account, FORWARD, target, quote
            );
        }
        this.conversation_list_view.selection_mode_enabled = false;
    }

    private void on_email_unsubscribe(Convey.Email target) {
        if (this.selected_account != null) {
            this.unsubscribe.begin(this.selected_account, target);
        }
    }

    private async void unsubscribe(Convey.Account account, Convey.Email email) {
        string? one_click = Convey.RFC822.Utils.has_one_click_unsubscribe(email)
            ? Convey.RFC822.Utils.get_list_unsubscribe_uri(email, { "https" })
            : null;
        string? mailto = Convey.RFC822.Utils.get_list_unsubscribe_uri(
            email, { "mailto" }
        );
        string? website = Convey.RFC822.Utils.get_list_unsubscribe_uri(
            email, { "https", "http" }
        );
        bool automatic = one_click != null || mailto != null;

        Convey.RFC822.MailboxAddress? originator =
            Util.Email.get_primary_originator(email);
        string sender = originator != null
            ? originator.to_short_display()
            : _("this mailing list");

        var dialog = new Adw.AlertDialog(
            // Translators: Title of the unsubscribe confirmation,
            // substitution is the sender's name
            _("Unsubscribe from %s?").printf(sender),
            automatic
            ? _("Convey will ask the sender to stop sending you emails.")
            : _("To unsubscribe, go to the sender’s website.")
        );
        dialog.add_response("cancel", _("_Cancel"));
        dialog.add_response(
            "unsubscribe", automatic ? _("_Unsubscribe") : _("_Go to Website")
        );
        dialog.default_response = "unsubscribe";
        dialog.close_response = "cancel";
        dialog.set_response_appearance(
            "unsubscribe", Adw.ResponseAppearance.SUGGESTED
        );
        if ((yield dialog.choose(this, null)) != "unsubscribe") {
            return;
        }

        try {
            if (one_click != null) {
                yield send_one_click_unsubscribe(one_click);
                // Translators: Toast shown after unsubscribing,
                // substitution is the sender's name
                add_toast(new Adw.Toast(_("Unsubscribed from %s").printf(sender)));
            } else if (mailto != null) {
                yield send_mailto_unsubscribe(account, email, mailto);
                // Translators: Toast shown after sending an unsubscribe
                // email, substitution is the sender's name
                add_toast(new Adw.Toast(
                    _("Unsubscribe request sent to %s").printf(sender)
                ));
            } else {
                yield new Gtk.UriLauncher(website).launch(this, null);
            }
        } catch (GLib.Error err) {
            handle_error(account.information, err);
        }
    }

    private async void send_one_click_unsubscribe(string uri)
        throws GLib.Error {
        var message = new Soup.Message.from_uri(
            "POST", GLib.Uri.parse(uri, GLib.UriFlags.NONE)
        );
        message.set_request_body_from_bytes(
            "application/x-www-form-urlencoded",
            new GLib.Bytes("List-Unsubscribe=One-Click".data)
        );
        yield new Soup.Session().send_and_read_async(
            message, GLib.Priority.DEFAULT, null
        );
        if (message.status_code < 200 || message.status_code >= 300) {
            throw new GLib.IOError.FAILED(
                "Unsubscribe request failed: %u %s",
                message.status_code,
                message.reason_phrase
            );
        }
    }

    private async void send_mailto_unsubscribe(Convey.Account account,
                                               Convey.Email email,
                                               string mailto)
        throws GLib.Error {
        GLib.Uri uri = GLib.Uri.parse(mailto, GLib.UriFlags.NONE);
        string? subject = null;
        string? body = null;
        string? query = uri.get_query();
        if (query != null) {
            HashTable<string,string> params = GLib.Uri.parse_params(
                query, -1, "&", GLib.UriParamsFlags.CASE_INSENSITIVE
            );
            subject = params.get("subject");
            body = params.get("body");
        }

        Convey.RFC822.MailboxAddress from = account.information.primary_mailbox;
        foreach (var mailbox in account.information.sender_mailboxes) {
            if ((email.to != null && email.to.contains_normalized(mailbox.address)) ||
                (email.cc != null && email.cc.contains_normalized(mailbox.address))) {
                from = mailbox;
                break;
            }
        }

        var composed = new Convey.ComposedEmail(
            new GLib.DateTime.now_local(),
            new Convey.RFC822.MailboxAddresses.single(from)
        );
        composed.set_to(new Convey.RFC822.MailboxAddresses.single(
            new Convey.RFC822.MailboxAddress(null, uri.get_path())
        ));
        composed.set_subject(subject ?? "Unsubscribe");
        composed.body_text = body ?? "Unsubscribe";

        var smtp = account.outgoing as Convey.Smtp.ClientService;
        if (smtp != null) {
            yield smtp.send_email(composed, null);
        } else {
            yield account.send_composed_email(composed, null);
        }
    }

    private void on_email_trash(ConversationListBox view, Convey.Email target) {
        do_trash_email.begin(view, target);
    }

    private async void do_trash_email(ConversationListBox view, Convey.Email target) {
        Convey.Folder? source = folder_for(view);
        if (source == null)
            return;

        try {
            yield this.controller.move_messages_special(
                source,
                TRASH,
                Convey.Collection.single(view.conversation),
                Convey.Collection.single(target.id));
        } catch (GLib.Error err) {
            handle_error(source.account.information, err);
        }
    }

    private void on_email_delete(ConversationListBox view, Convey.Email target) {
        do_delete_email.begin(view, target);
    }

    private async void do_delete_email(ConversationListBox view, Convey.Email target) {
        Convey.FolderSupport.Remove? source =
            folder_for(view) as Convey.FolderSupport.Remove;
        if (source == null || !yield prompt_delete_messages(1))
            return;

        try {
            yield this.controller.delete_messages(
                source,
                Convey.Collection.single(view.conversation),
                Convey.Collection.single(target.id));
        } catch (GLib.Error err) {
            handle_error(source.account.information, err);
        }
    }
}
