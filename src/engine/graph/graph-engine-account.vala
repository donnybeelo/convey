/*
 * Copyright 2026 Daniel Elia <d.elia@outlook.com>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

internal class Convey.Graph.Account : Convey.Account,
    Convey.AccountSupport.QueueSend {

    private const string REMOTE_ROOT_LABEL = "$convey-graph";
    private const uint POLL_INTERVAL_SEC = 30;
    // Every Nth poll tick runs a full sync instead of the fast poll: the
    // folder list is re-synced and all folders are refreshed, not just the
    // inbox and open folders.
    private const uint FULL_SYNC_EVERY_N_TICKS = 10;
    // Adaptive cadence: fast polls run every poll_stride ticks. Activity
    // (new mail, user actions) resets the stride to 1 (30s); quiet polls
    // double it up to this cap (120s), keeping idle radio wakeups low.
    private const uint MAX_POLL_STRIDE = 4;

    // Well-known names used by Microsoft Graph for the built-in special folders.
    // These are already registered as hardcoded folders, so we skip them when
    // syncing custom (user-created) folders from the API.
    private const string[] BUILTIN_WELL_KNOWN_NAMES = {
        "inbox",
        "sentitems",
        "drafts",
        "deleteditems",
        "junkemail",
        "archive",
        "outbox",
    };

    // Display names that Microsoft Graph uses for built-in folders in English
    // and a selection of other locales. Used as a secondary filter when the
    // wellKnownName field is absent from the API response.
    private const string[] BUILTIN_DISPLAY_NAMES = {
        // English
        "inbox",
        "sent items",
        "sent",
        "drafts",
        "deleted items",
        "junk email",
        "junk",
        "archive",
        "outbox",
        "conversation history",
        "rss feeds",
        "sync issues",
    };

    private Convey.FolderRoot remote_folder_root =
        new Convey.FolderRoot(REMOTE_ROOT_LABEL, false);
    private Gee.TreeMap<Convey.FolderPath,Convey.Folder> remote_folders =
        new Gee.TreeMap<Convey.FolderPath,Convey.Folder>((a, b) => a.compare_to(b));
    private Gee.TreeMap<Convey.FolderPath,Convey.Folder> local_folders =
        new Gee.TreeMap<Convey.FolderPath,Convey.Folder>((a, b) => a.compare_to(b));
    private Gee.HashMap<Convey.Folder.SpecialUse,Convey.Graph.Folder> special_folders =
        new Gee.HashMap<Convey.Folder.SpecialUse,Convey.Graph.Folder>();

    private Gee.ArrayList<Convey.Folder> get_remote_folder_snapshot() {
        Gee.ArrayList<Convey.Folder> folders = new Gee.ArrayList<Convey.Folder>();
        folders.add_all(this.remote_folders.values);
        return folders;
    }

    private Convey.Graph.Client client;
    private Convey.TimeoutManager poll_timer;
    private uint poll_tick = 0;
    private uint poll_stride = 1;
    private bool screen_locked = false;
    private GLib.DBusConnection? session_bus = null;
    private uint screensaver_subscription = 0;
    private GLib.Cancellable? poll_cancellable = null;
    private bool is_account_open = false;
    private bool prefetch_refresh_running = false;
    private bool prefetch_refresh_pending = false;
    private Convey.App.SearchFolder? starred_folder = null;


    public Account(Convey.AccountInformation information,
                   Convey.Endpoint incoming_remote,
                   Convey.Endpoint outgoing_remote) {
        base(
            information,
            new Convey.Graph.Service(information, information.incoming, incoming_remote),
            new Convey.Graph.Service(information, information.outgoing, outgoing_remote)
        );
        this.contact_store = new Convey.Graph.SentContactStore(this);
        this.background_progress = new Convey.ReentrantProgressMonitor(
            Convey.ProgressType.ACTIVITY
        );
        this.db_upgrade_monitor = new Convey.ReentrantProgressMonitor(
            Convey.ProgressType.ACTIVITY
        );
        this.db_vacuum_monitor = new Convey.ReentrantProgressMonitor(
            Convey.ProgressType.ACTIVITY
        );
        this.client = new Convey.Graph.Client(information);
        this.client.response_received.connect(
            ((Convey.Graph.Service) this.incoming).notify_response_received
        );
        this.poll_timer = new Convey.TimeoutManager.seconds(
            POLL_INTERVAL_SEC,
            on_poll_tick
        );
        this.poll_timer.repetition = Convey.TimeoutManager.Repeat.FOREVER;
        this.poll_timer.start();
        this.information.notify["prefetch-period-days"].connect((obj, pspec) => {
            queue_prefetch_refresh();
        });

        this.notify["local-starred-folder"].connect(() => register_starred_folder());

        add_folder("Inbox", "inbox", Convey.Folder.SpecialUse.INBOX);
        add_folder("Sent", "sentitems", Convey.Folder.SpecialUse.SENT);
        add_folder("Drafts", "drafts", Convey.Folder.SpecialUse.DRAFTS);
        add_folder("Trash", "deleteditems", Convey.Folder.SpecialUse.TRASH);
        add_folder("Junk", "junkemail", Convey.Folder.SpecialUse.JUNK);
        add_folder("Archive", "archive", Convey.Folder.SpecialUse.ARCHIVE);
        add_folder("Outbox", "outbox", Convey.Folder.SpecialUse.OUTBOX);
    }

    private void register_starred_folder() throws GLib.Error {
        if (this.local_starred_folder && this.starred_folder == null) {
            this.starred_folder = new Convey.App.SearchFolder(
                this,
                this.local_folder_root,
                Convey.App.SearchFolder.STARRED_BASENAME,
                Convey.Folder.SpecialUse.FLAGGED
            );
            var terms = new Gee.ArrayList<Convey.SearchQuery.Term>();
            terms.add(new Convey.SearchQuery.EmailFlagTerm(Convey.EmailFlags.FLAGGED));
            this.starred_folder.update_query(new_search_query(terms, "is:starred"));
            register_local_folder(this.starred_folder);
        } else if (!this.local_starred_folder && this.starred_folder != null) {
            deregister_local_folder(this.starred_folder);
            this.starred_folder = null;
        }
    }

    public override async void open_async(GLib.Cancellable? cancellable = null)
        throws GLib.Error {
        if (this.is_account_open) {
            return;
        }

        yield this.incoming.start(cancellable);
        yield this.outgoing.start(cancellable);

        this.is_account_open = true;

        // Must exist before load_cached_folders() so junk emails don't appear
        // in the starred folder.
        this.register_starred_folder();

        // Publish the folder list without touching the network: the built-ins
        // are hardcoded and custom folders come from the on-disk cache. The
        // server sync then runs in the background and notifies the difference.
        load_cached_folders();
        notify_folders_available_unavailable(
            sort_by_path(get_remote_folder_snapshot()),
            null
        );
        sync_custom_folders_async.begin(cancellable, (obj, res) => {
            try {
                sync_custom_folders_async.end(res);
            } catch (GLib.Error err) {
                debug("Graph: Failed to sync custom folders on open: %s", err.message);
            }
        });
        notify_opened();
        Convey.Graph.Folder? inbox =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.INBOX);
        if (inbox != null) {
            inbox.load_persisted_cache();
        }
        // Load Junk as well so its unread counter is available without
        // manually opening the folder.
        Convey.Graph.Folder? junk =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.JUNK);
        if (junk != null) {
            junk.load_persisted_cache();
        }
        // Load Sent so conversation threading can see our own replies
        // without the folder ever being opened.
        Convey.Graph.Folder? sent =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.SENT);
        if (sent != null) {
            sent.load_persisted_cache();
        }
        subscribe_screensaver();
        queue_prefetch_refresh();
    }

    public override async void close_async(GLib.Cancellable? cancellable = null)
        throws GLib.Error {
        if (!this.is_account_open) {
            return;
        }

        foreach (Convey.Folder folder in list_folders()) {
            if (folder.get_open_state() != Convey.Folder.OpenState.CLOSED) {
                yield folder.close_async(cancellable);
            }
        }

        notify_folders_available_unavailable(
            null,
            sort_by_path(list_folders())
        );

        yield this.outgoing.stop(cancellable);
        yield this.incoming.stop(cancellable);

        if (this.screensaver_subscription != 0) {
            this.session_bus.signal_unsubscribe(this.screensaver_subscription);
            this.screensaver_subscription = 0;
        }

        if (this.starred_folder != null) {
            deregister_local_folder(this.starred_folder);
            this.starred_folder = null;
        }

        this.is_account_open = false;
        notify_closed();
    }

    /**
     * Pauses polling while the screen is locked; nobody is reading mail.
     *
     * GNOME-only signal — on other desktops it never fires and polling just
     * continues as before. Unsubscribed on close so the connection's strong
     * reference can't keep a closed account polling.
     */
    private void subscribe_screensaver() {
        GLib.Bus.get.begin(GLib.BusType.SESSION, null, (obj, res) => {
            try {
                this.session_bus = GLib.Bus.get.end(res);
            } catch (GLib.Error err) {
                debug("Graph: no session bus, lock detection disabled: %s",
                    err.message);
                return;
            }
            if (!this.is_account_open || this.screensaver_subscription != 0) {
                return;
            }
            this.screensaver_subscription = this.session_bus.signal_subscribe(
                null,
                "org.gnome.ScreenSaver",
                "ActiveChanged",
                "/org/gnome/ScreenSaver",
                null,
                GLib.DBusSignalFlags.NONE,
                (conn, sender, path, iface, name, parameters) => {
                    bool locked = false;
                    parameters.get("(b)", out locked);
                    bool was_locked = this.screen_locked;
                    this.screen_locked = locked;
                    if (was_locked && !locked) {
                        trigger_immediate_poll();
                    }
                }
            );
        });
    }

    public override bool is_open() {
        return this.is_account_open;
    }

    public override void cancel_remote_update() {
        this.prefetch_refresh_pending = false;
        queue_prefetch_refresh();
    }

    public override async void rebuild_async(GLib.Cancellable? cancellable = null)
        throws GLib.Error {
    }

    public override Convey.EmailIdentifier to_email_identifier(GLib.Variant serialised)
        throws Convey.EngineError.BAD_PARAMETERS {
        return new Convey.Graph.EmailIdentifier.from_variant(serialised);
    }

    public override Convey.FolderPath to_folder_path(GLib.Variant serialised)
        throws Convey.EngineError.BAD_PARAMETERS {
        string root = serialised.get_child_value(0).get_string();
        if (root == this.local_folder_root.label) {
            return this.local_folder_root.from_variant(serialised);
        }
        if (root == this.remote_folder_root.label) {
            return this.remote_folder_root.from_variant(serialised);
        }
        throw new Convey.EngineError.BAD_PARAMETERS(
            "Invalid serialised folder root label: %s", root
        );
    }

    public override Convey.Folder get_folder(Convey.FolderPath path)
        throws Convey.EngineError.NOT_FOUND {
        Convey.Folder? folder = this.remote_folders.get(path);
        if (folder == null) {
            folder = this.local_folders.get(path);
        }
        if (folder == null) {
            throw new Convey.EngineError.NOT_FOUND(
                "Unknown folder: %s", path.to_string()
            );
        }
        return folder;
    }

    public override Gee.Collection<Convey.Folder> list_folders() {
        Gee.ArrayList<Convey.Folder> folders = get_remote_folder_snapshot();
        folders.add_all(this.local_folders.values);
        return folders.read_only_view;
    }

    public override Gee.Collection<Convey.Folder> list_matching_folders(Convey.FolderPath? parent)
        throws Convey.EngineError.NOT_FOUND {
        if (parent == null) {
            return list_folders();
        }
        if (!this.remote_folders.has_key(parent) && !this.local_folders.has_key(parent)) {
            throw new Convey.EngineError.NOT_FOUND(
                "Unknown parent folder: %s", parent.to_string()
            );
        }
        Gee.ArrayList<Convey.Folder> matched = new Gee.ArrayList<Convey.Folder>();
        foreach (Convey.Folder folder in list_folders()) {
            if (folder.path != parent && folder.path.is_descendant(parent)) {
                matched.add(folder);
            }
        }
        return matched.read_only_view;
    }

    public override async Convey.Folder get_required_special_folder_async(
        Convey.Folder.SpecialUse special,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        Convey.Graph.Folder? folder = this.special_folders.get(special);
        if (folder == null) {
            throw new Convey.EngineError.NOT_FOUND(
                "No Graph folder for special use: %s",
                Convey.ObjectUtils.to_enum_nick(typeof(Convey.Folder.SpecialUse), special)
            );
        }
        return folder;
    }

    public override async Convey.Folder create_personal_folder(
        string name,
        Convey.Folder.SpecialUse use = Convey.Folder.SpecialUse.NONE,
        GLib.Cancellable? cancellable = null,
        Convey.Folder? parent = null
    ) throws GLib.Error {
        if (!this.is_account_open) {
            throw new Convey.EngineError.OPEN_REQUIRED("Account not open");
        }
        if (use != Convey.Folder.SpecialUse.NONE) {
            throw new Convey.EngineError.UNSUPPORTED(
                "Setting special-use on create is not supported for Graph accounts"
            );
        }
        Convey.Graph.Folder? graph_parent = parent as Convey.Graph.Folder;
        if (parent != null && graph_parent == null) {
            throw new Convey.EngineError.NOT_FOUND(
                "Parent folder is not a Graph folder"
            );
        }
        Convey.FolderPath parent_path = (graph_parent != null)
            ? graph_parent.path
            : this.remote_folder_root;
        Convey.Graph.Client.MailFolder created =
            yield this.client.create_mail_folder(
                name,
                (graph_parent != null) ? graph_parent.graph_folder_id : null,
                cancellable
            );
        Convey.FolderPath path = parent_path.get_child(created.display_name);
        Convey.Graph.Folder? existing = this.remote_folders.get(path) as Convey.Graph.Folder;
        if (existing != null) {
            return existing;
        }
        Convey.Graph.Folder folder = add_folder(
            created.display_name,
            created.id,
            Convey.Folder.SpecialUse.NONE,
            parent_path
        );
        notify_folders_available_unavailable(
            sort_by_path(Collection.single(folder)),
            null
        );
        notify_folders_created(sort_by_path(Collection.single(folder)));
        return folder;
    }

    public override async void delete_folder(Convey.Folder folder,
                                             GLib.Cancellable? cancellable = null)
        throws GLib.Error {
        Convey.Graph.Folder target = check_folder_is_mutable(folder);
        yield this.client.delete_mail_folder(target.graph_folder_id, cancellable);
        remove_folder(target.path);
    }

    public override async Convey.Folder rename_folder(Convey.Folder folder,
                                                      string new_name,
                                                      GLib.Cancellable? cancellable = null)
        throws GLib.Error {
        Convey.Graph.Folder target = check_folder_is_mutable(folder);
        Convey.FolderPath path = this.remote_folder_root.get_child(new_name);
        if (this.remote_folders.has_key(path)) {
            throw new Convey.EngineError.ALREADY_EXISTS(
                "Folder already exists: %s", path.to_string()
            );
        }

        Convey.Graph.Client.MailFolder renamed = yield this.client.rename_mail_folder(
            target.graph_folder_id, new_name, cancellable
        );

        remove_folder(target.path);
        Convey.Graph.Folder created = add_folder(
            renamed.display_name,
            renamed.id,
            Convey.Folder.SpecialUse.NONE
        );
        notify_folders_available_unavailable(
            sort_by_path(Collection.single(created)),
            null
        );
        notify_folders_created(sort_by_path(Collection.single(created)));
        return created;
    }

    /**
     * Returns the folder unless it is special-use or not ours.
     */
    private Convey.Graph.Folder check_folder_is_mutable(Convey.Folder folder)
        throws GLib.Error {
        if (!this.is_account_open) {
            throw new Convey.EngineError.OPEN_REQUIRED("Account not open");
        }
        Convey.Graph.Folder? target =
            this.remote_folders.get(folder.path) as Convey.Graph.Folder;
        if (target == null || target != folder) {
            throw new Convey.EngineError.NOT_FOUND(
                "Not a remote folder for this account: %s", folder.path.to_string()
            );
        }
        if (target.used_as != Convey.Folder.SpecialUse.NONE) {
            throw new Convey.EngineError.UNSUPPORTED(
                "Cannot modify special folder: %s", folder.path.to_string()
            );
        }
        return target;
    }

    public override void register_local_folder(Convey.Folder local)
        throws GLib.Error {
        Convey.FolderPath path = local.path;
        if (this.local_folders.has_key(path)) {
            throw new Convey.EngineError.ALREADY_EXISTS(
                "Folder already registered: %s", path.to_string()
            );
        }
        if (!this.local_folder_root.is_descendant(path)) {
            throw new Convey.EngineError.NOT_FOUND(
                "Not a descendant of local folder root: %s", path.to_string()
            );
        }
        this.local_folders.set(path, local);
        notify_folders_available_unavailable(sort_by_path(Collection.single(local)), null);
    }

    public override void deregister_local_folder(Convey.Folder local)
        throws GLib.Error {
        Convey.FolderPath path = local.path;
        if (!this.local_folders.has_key(path)) {
            throw new Convey.EngineError.NOT_FOUND(
                "Unknown local folder: %s", path.to_string()
            );
        }
        notify_folders_available_unavailable(null, sort_by_path(Collection.single(local)));
        this.local_folders.unset(path);
    }

    public override async Gee.MultiMap<Convey.Email, Convey.FolderPath?>? local_search_message_id_async(
        Convey.RFC822.MessageID message_id,
        Convey.Email.Field requested_fields,
        bool partial_ok,
        Gee.Collection<Convey.FolderPath?>? folder_blacklist,
        Convey.EmailFlags? flag_blacklist,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        Convey.Email.Field required = requested_fields;
        if (flag_blacklist != null) {
            required = required | Convey.Email.Field.FLAGS;
        }

        Gee.HashMultiMap<Convey.Email, Convey.FolderPath?> matches =
            new Gee.HashMultiMap<Convey.Email, Convey.FolderPath?>();
        string needle = message_id.to_rfc822_string();
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            if (folder_blacklist != null && folder_blacklist.contains(folder.path)) {
                continue;
            }
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph == null) {
                continue;
            }
            if (!graph.is_cache_loaded &&
                folder.used_as == Convey.Folder.SpecialUse.SENT) {
                graph.load_persisted_cache();
            }
            if (!graph.is_cache_loaded) {
                continue;
            }
            foreach (Convey.Email cached in graph.list_cached_emails()) {
                if (!matches_message_id(cached, needle)) {
                    continue;
                }
                Convey.Email email = cached;
                if (!partial_ok && !email.fields.fulfills(required)) {
                    if (graph.get_open_state() != Convey.Folder.OpenState.CLOSED) {
                        email = yield graph.fetch_email_async(
                            cached.id,
                            required,
                            Convey.Folder.ListFlags.NONE,
                            cancellable
                        );
                    } else {
                        continue;
                    }
                }
                if (!partial_ok && !email.fields.fulfills(required)) {
                    continue;
                }
                if (flag_blacklist != null &&
                    email.email_flags != null &&
                    email.email_flags.contains_any(flag_blacklist)) {
                    continue;
                }
                matches.set(email, folder.path);
            }
        }
        return matches.size > 0 ? matches : null;
    }

    public override async Convey.Email local_fetch_email_async(
        Convey.EmailIdentifier email_id,
        Convey.Email.Field required_fields,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph != null && graph.has_cached_identifier(email_id)) {
                return yield graph.fetch_email_async(
                    email_id,
                    required_fields,
                    Convey.Folder.ListFlags.NONE,
                    cancellable
                );
            }
        }
        throw new Convey.EngineError.NOT_FOUND(
            "Unknown Graph email identifier: %s", email_id.to_string()
        );
    }

    public override async Gee.List<Convey.Email> list_local_email_async(
        Gee.Collection<Convey.EmailIdentifier> ids,
        Convey.Email.Field required_fields,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        Gee.ArrayList<Convey.Email> listed = new Gee.ArrayList<Convey.Email>();
        foreach (Convey.EmailIdentifier id in ids) {
            listed.add(yield local_fetch_email_async(id, required_fields, cancellable));
        }
        return listed;
    }

    public override Convey.SearchQuery new_search_query(
        Gee.List<Convey.SearchQuery.Term> expression,
        string text
    ) throws GLib.Error {
        return new Convey.Graph.SearchQuery(expression, text);
    }

    public override async Gee.Collection<Convey.EmailIdentifier>? local_search_async(
        Convey.SearchQuery query,
        int limit = 100,
        int offset = 0,
        Gee.Collection<Convey.FolderPath?>? folder_blacklist = null,
        Gee.Collection<Convey.EmailIdentifier>? search_ids = null,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        Gee.Set<Convey.EmailIdentifier>? search_scope = null;
        if (search_ids != null) {
            search_scope = new Gee.HashSet<Convey.EmailIdentifier>();
            search_scope.add_all(search_ids);
        }

        Gee.ArrayList<Convey.Email> matched = new Gee.ArrayList<Convey.Email>();
        Gee.Set<Convey.EmailIdentifier> seen = new Gee.HashSet<Convey.EmailIdentifier>();
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            if (cancellable != null && cancellable.is_cancelled()) {
                throw new GLib.IOError.CANCELLED("Graph search cancelled");
            }
            if (folder_blacklist != null && folder_blacklist.contains(folder.path)) {
                continue;
            }
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph == null) {
                continue;
            }
            if (!graph.is_cache_loaded) {
                graph.load_persisted_cache();
            }
            if (!graph.is_cache_loaded) {
                continue;
            }
            foreach (Convey.Email email in graph.list_cached_emails()) {
                if (search_scope != null && !search_scope.contains(email.id)) {
                    continue;
                }
                if (!email_matches_query(email, query)) {
                    continue;
                }
                if (seen.add(email.id)) {
                    matched.add(email);
                }
            }
        }

        if (matched.is_empty) {
            return null;
        }
        matched.sort((a, b) => Convey.Email.compare_recv_date_descending(a, b));

        int start = int.max(0, offset);
        int max_results = (limit > 0) ? limit : matched.size;
        if (start >= matched.size || max_results <= 0) {
            return null;
        }

        Gee.ArrayList<Convey.EmailIdentifier> ids =
            new Gee.ArrayList<Convey.EmailIdentifier>();
        for (int i = start; i < matched.size && ids.size < max_results; i++) {
            ids.add(matched[i].id);
        }
        return ids.is_empty ? null : ids;
    }

    public override async Gee.Set<string>? get_search_matches_async(
        Convey.SearchQuery query,
        Gee.Collection<Convey.EmailIdentifier> ids,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        Gee.Set<Convey.EmailIdentifier> id_set = new Gee.HashSet<Convey.EmailIdentifier>();
        id_set.add_all(ids);

        Gee.Set<string> matches = new Gee.HashSet<string>();
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            if (cancellable != null && cancellable.is_cancelled()) {
                throw new GLib.IOError.CANCELLED("Graph search matches cancelled");
            }
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph == null) {
                continue;
            }
            if (!graph.is_cache_loaded) {
                graph.load_persisted_cache();
            }
            if (!graph.is_cache_loaded) {
                continue;
            }
            foreach (Convey.Email email in graph.list_cached_emails()) {
                if (!id_set.contains(email.id)) {
                    continue;
                }
                Gee.Set<string>? email_matches = get_query_matches(email, query);
                if (email_matches != null) {
                    matches.add_all(email_matches);
                }
            }
        }
        return matches.is_empty ? null : matches;
    }

    public override async Gee.MultiMap<Convey.EmailIdentifier, Convey.FolderPath>? get_containing_folders_async(
        Gee.Collection<Convey.EmailIdentifier> ids,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        Gee.HashMultiMap<Convey.EmailIdentifier, Convey.FolderPath> containing =
            new Gee.HashMultiMap<Convey.EmailIdentifier, Convey.FolderPath>();
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph == null || !graph.is_cache_loaded) {
                continue;
            }
            foreach (Convey.EmailIdentifier id in ids) {
                if (graph.has_cached_identifier(id)) {
                    containing.set(id, folder.path);
                }
            }
        }
        var locals = new Gee.ArrayList<Convey.Folder>();
        locals.add_all(this.local_folders.values);
        foreach (Convey.Folder folder in locals) {
            foreach (var id in yield folder.contains_identifiers(ids, cancellable)) {
                containing.set(id, folder.path);
            }
        }
        return containing.size > 0 ? containing : null;
    }

    public override async void cleanup_storage(GLib.Cancellable? cancellable)
        throws GLib.Error {
    }

    public override async void send_composed_email(
        Convey.ComposedEmail composed,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        string message_id = yield save_email(composed, cancellable);
        yield queue_email(message_id, cancellable);
    }

    /**
     * Stages a composed email into Outlook's Outbox folder without sending it.
     *
     * Returns the Graph message ID of the staged message. Pass it to
     * {@link queue_email} to deliver it, or to {@link discard_staged_email}
     * to remove it (undo).
     */
    public async string save_email(
        Convey.ComposedEmail composed,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        string message_id =
            yield this.client.create_message_in_outbox(composed, cancellable);
        // Refresh Drafts and Outbox so the staged message moves cleanly in
        // the folder views once the draft is relocated.
        Convey.Graph.Folder? drafts =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.DRAFTS);
        if (drafts != null && drafts.is_cache_loaded) {
            yield drafts.refresh_async(true, cancellable);
        }
        Convey.Graph.Folder? outbox =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.OUTBOX);
        if (outbox != null && outbox.is_cache_loaded) {
            yield outbox.refresh_async(true, cancellable);
        }
        return message_id;
    }

    /**
     * Sends a message previously staged by {@link save_email}.
     *
     * The server delivers the message and moves it to Sent Items automatically.
     */
    public async void queue_email(
        string message_id,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        yield this.client.send_message(message_id, cancellable);
        email_sent();
        // Refresh Sent so the newly-delivered message shows up in threads,
        // loading it first if this session hasn't touched it yet.
        Convey.Graph.Folder? sent =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.SENT);
        if (sent != null) {
            sent.load_persisted_cache();
            yield sent.refresh_async(true, cancellable);
        }
        // Refresh Outbox so the now-sent message disappears
        Convey.Graph.Folder? outbox =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.OUTBOX);
        if (outbox != null && outbox.is_cache_loaded) {
            yield outbox.refresh_async(true, cancellable);
        }
    }

    /**
     * Discards a message previously staged by {@link save_email} (undo send).
     */
    public async void discard_staged_email(
        string message_id,
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        yield this.client.delete_message(message_id, cancellable);
        Convey.Graph.Folder? outbox =
            this.get_graph_special_folder(Convey.Folder.SpecialUse.OUTBOX);
        if (outbox != null && outbox.is_cache_loaded) {
            yield outbox.refresh_async(true, cancellable);
        }
    }

    protected override void
        notify_folders_available_unavailable(Gee.BidirSortedSet<Convey.Folder>? available,
                                             Gee.BidirSortedSet<Convey.Folder>? unavailable) {
        base.notify_folders_available_unavailable(available, unavailable);
        if (available != null) {
            foreach (Convey.Folder folder in available) {
                if (!(folder is Convey.Graph.Folder)) {
                    continue;
                }
                folder.email_appended.connect(notify_email_appended);
                folder.email_inserted.connect(notify_email_inserted);
                folder.email_removed.connect(notify_email_removed);
                folder.email_locally_removed.connect(notify_email_locally_removed);
                folder.email_locally_complete.connect(notify_email_locally_complete);
                folder.email_flags_changed.connect(notify_email_flags_changed);
            }
        }
        if (unavailable != null) {
            foreach (Convey.Folder folder in unavailable) {
                if (!(folder is Convey.Graph.Folder)) {
                    continue;
                }
                folder.email_appended.disconnect(notify_email_appended);
                folder.email_inserted.disconnect(notify_email_inserted);
                folder.email_removed.disconnect(notify_email_removed);
                folder.email_locally_removed.disconnect(notify_email_locally_removed);
                folder.email_locally_complete.disconnect(notify_email_locally_complete);
                folder.email_flags_changed.disconnect(notify_email_flags_changed);
            }
        }
    }

    internal Convey.Graph.Folder? get_graph_folder(Convey.FolderPath path) {
        return this.remote_folders.get(path) as Convey.Graph.Folder;
    }

    internal Convey.Graph.Folder? get_graph_special_folder(Convey.Folder.SpecialUse use) {
        return this.special_folders.get(use);
    }

    private Convey.Graph.Folder add_folder(string name,
                                          string graph_id,
                                          Convey.Folder.SpecialUse use,
                                          FolderPath? parent = null) {
        FolderPath root = parent ?? this.remote_folder_root;
        Convey.FolderPath path = root.get_child(name);
        Convey.Graph.Folder folder = new Convey.Graph.Folder(
            this,
            this.client,
            path,
            graph_id,
            use
        );
        this.remote_folders.set(path, folder);
        if (use != Convey.Folder.SpecialUse.NONE) {
            this.special_folders.set(use, folder);
        }
        return folder;
    }

    private void remove_folder(Convey.FolderPath path) {
        Convey.Folder? folder = this.remote_folders.get(path);
        if (folder == null) {
            return;
        }
        this.remote_folders.unset(path);
        notify_folders_available_unavailable(
            null,
            sort_by_path(Collection.single(folder))
        );
        notify_folders_deleted(sort_by_path(Collection.single(folder)));
    }

    private Convey.Graph.Folder? find_folder_by_graph_id(string graph_id) {
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph != null && graph.graph_folder_id == graph_id) {
                return graph;
            }
        }
        return null;
    }

    private async void sync_custom_folders_async(
        GLib.Cancellable? cancellable = null
    ) throws GLib.Error {
        Gee.HashMap<string,Convey.FolderPath> seen =
            new Gee.HashMap<string,Convey.FolderPath>();
        Gee.ArrayList<Convey.Folder> added = new Gee.ArrayList<Convey.Folder>();
        Gee.HashMap<string,string> builtin_ids = new Gee.HashMap<string,string>();
        foreach (string name in BUILTIN_WELL_KNOWN_NAMES) {
            try {
                builtin_ids.set(
                    yield this.client.get_mail_folder_id(name, cancellable),
                    name
                );
            } catch (GLib.Error err) {
                debug("Graph: No built-in folder '%s': %s", name, err.message);
            }
        }
        yield walk_folders(null, this.remote_folder_root, seen, added, builtin_ids, cancellable);

        // Remove folders that no longer exist on the server
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph != null &&
                graph.used_as == Convey.Folder.SpecialUse.NONE &&
                !seen.has_key(graph.graph_folder_id)) {
                debug("Graph: Removing custom folder '%s' (no longer on server)",
                    folder.path.to_string());
                remove_folder(folder.path);
            }
        }

        // Notify the UI about newly discovered folders (only after account is open,
        // otherwise open_async itself will fire the initial availability notification)
        if (this.is_account_open && !added.is_empty) {
            notify_folders_available_unavailable(
                sort_by_path(added),
                null
            );
            notify_folders_created(sort_by_path(added));
        }

        persist_cached_folders();
    }

    /**
     * Registers the subtree below a folder, depth first.
     *
     * Built-in folders are hardcoded, so they are walked into but not
     * registered; folders that aren't shown have their subtree skipped.
     */
    private async void walk_folders(string? parent_id,
                                    Convey.FolderPath parent_path,
                                    Gee.Map<string,Convey.FolderPath> seen,
                                    Gee.List<Convey.Folder> added,
                                    Gee.Map<string,string> builtin_ids,
                                    GLib.Cancellable? cancellable)
        throws GLib.Error {
        Gee.List<Convey.Graph.Client.MailFolder> children;
        try {
            children = yield this.client.list_mail_folders(parent_id, cancellable);
        } catch (GLib.Error err) {
            if (parent_id == null) {
                throw err;
            }
            debug("Graph: Failed to list children of '%s': %s",
                parent_path.to_string(), err.message);
            return;
        }

        foreach (Convey.Graph.Client.MailFolder mf in children) {
            if (mf.is_hidden || String.is_empty(mf.display_name)) {
                continue;
            }

            string well_known = mf.well_known_name.down();
            if (String.is_empty(well_known)) {
                well_known = builtin_ids.get(mf.id) ?? "";
            }
            Convey.FolderPath path;
            if (well_known in BUILTIN_WELL_KNOWN_NAMES) {
                Convey.Graph.Folder? builtin = find_folder_by_graph_id(well_known);
                if (builtin == null) {
                    continue;
                }
                path = builtin.path;
            } else if (String.is_empty(well_known) &&
                       mf.display_name.down() in BUILTIN_DISPLAY_NAMES) {
                continue;
            } else {
                path = parent_path.get_child(mf.display_name);
                Convey.Graph.Folder? tracked = find_folder_by_graph_id(mf.id);
                if (tracked != null && !tracked.path.equal_to(path)) {
                    remove_folder(tracked.path);
                    tracked = null;
                }
                if (tracked == null) {
                    if (this.remote_folders.has_key(path)) {
                        debug("Graph: Skipping custom folder '%s' (%s): " +
                            "path already registered", mf.display_name, mf.id);
                        continue;
                    }
                    added.add(add_folder(
                        mf.display_name,
                        mf.id,
                        Convey.Folder.SpecialUse.NONE,
                        parent_path
                    ));
                    debug("Graph: Added custom folder '%s' (%s)",
                        path.to_string(), mf.id);
                }
                seen.set(mf.id, path);
            }

            if (mf.child_folder_count > 0) {
                yield walk_folders(mf.id, path, seen, added, builtin_ids, cancellable);
            }
        }
    }

    private string folders_cache_path() {
        GLib.File? data_dir = this.information.data_dir;
        // Fallback to ~/.local/share/convey if account data_dir isn't set.
        if (data_dir == null) {
            data_dir = GLib.File.new_for_path(
                GLib.Path.build_filename(
                    Environment.get_home_dir(), ".local", "share", "convey"
                )
            );
        }
        return data_dir.get_child("graph-cache").get_child("folders.json").get_path();
    }

    /**
     * Registers the custom folders saved by the last sync.
     *
     * Built-in folders are hardcoded in the constructor, so only custom
     * folders are cached.
     */
    private void load_cached_folders() {
        string path = folders_cache_path();
        if (!GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) {
            return;
        }
        try {
            string contents;
            size_t contents_length;
            GLib.FileUtils.get_contents(path, out contents, out contents_length);
            Json.Parser parser = new Json.Parser();
            parser.load_from_data(contents, (ssize_t) contents_length);
            Json.Node? root_node = parser.get_root();
            if (root_node == null || root_node.get_node_type() != Json.NodeType.OBJECT) {
                return;
            }
            Json.Object root = root_node.get_object();
            if (!root.has_member("folders") ||
                root.get_member("folders").get_node_type() != Json.NodeType.ARRAY) {
                return;
            }

            Json.Array folders = root.get_array_member("folders");
            for (uint i = 0; i < folders.get_length(); i++) {
                if (folders.get_element(i).get_node_type() != Json.NodeType.OBJECT) {
                    continue;
                }
                Json.Object entry = folders.get_object_element(i);
                string id = Client.get_string_member(entry, "id") ?? "";
                if (String.is_empty(id) || !entry.has_member("path")) {
                    continue;
                }
                Json.Array parts = entry.get_array_member("path");
                if (parts.get_length() == 0) {
                    continue;
                }
                Convey.FolderPath parent = this.remote_folder_root;
                for (uint p = 0; p + 1 < parts.get_length(); p++) {
                    parent = parent.get_child(parts.get_string_element(p));
                }
                string name = parts.get_string_element(parts.get_length() - 1);
                // Guard against a name that collides with an already-registered
                // folder path, as sync_custom_folders_async does.
                if (this.remote_folders.has_key(parent.get_child(name))) {
                    continue;
                }
                add_folder(name, id, Convey.Folder.SpecialUse.NONE, parent);
            }
        } catch (GLib.Error err) {
            warning("Error loading Graph folder cache: %s", err.message);
        }
    }

    private void persist_cached_folders() {
        string path = folders_cache_path();
        try {
            GLib.DirUtils.create_with_parents(GLib.Path.get_dirname(path), 0700);

            Json.Builder builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("folders");
            builder.begin_array();
            foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
                Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
                if (graph == null ||
                    graph.used_as != Convey.Folder.SpecialUse.NONE) {
                    continue;
                }
                builder.begin_object();
                builder.set_member_name("id");
                builder.add_string_value(graph.graph_folder_id);
                builder.set_member_name("path");
                builder.begin_array();
                foreach (string part in folder.path.as_array()) {
                    builder.add_string_value(part);
                }
                builder.end_array();
                builder.end_object();
            }
            builder.end_array();
            builder.end_object();

            Json.Node root = builder.get_root();
            Json.Generator generator = new Json.Generator();
            generator.set_root(root);
            string payload = generator.to_data(null);
            GLib.FileUtils.set_contents(path, payload);
        } catch (GLib.Error err) {
            warning("Error persisting Graph folder cache: %s", err.message);
        }
    }

    private static bool matches_message_id(Convey.Email email, string needle) {
        if (email.message_id != null &&
            email.message_id.to_rfc822_string() == needle) {
            return true;
        }
        Gee.Set<Convey.RFC822.MessageID>? ancestors = email.get_ancestors();
        if (ancestors == null) {
            return false;
        }
        foreach (Convey.RFC822.MessageID candidate in ancestors) {
            if (candidate.to_rfc822_string() == needle) {
                return true;
            }
        }
        return false;
    }

    private static bool email_matches_query(Convey.Email email, Convey.SearchQuery query) {
        if (query.expression.is_empty) {
            return !String.is_empty(query.raw) &&
                matches_text_term(
                    email,
                    Convey.SearchQuery.EmailTextTerm.Property.ALL,
                    query.raw
                );
        }
        foreach (Convey.SearchQuery.Term term in query.expression) {
            if (!matches_query_term(email, term)) {
                return false;
            }
        }
        return true;
    }

    private static Gee.Set<string>? get_query_matches(Convey.Email email, Convey.SearchQuery query) {
        Gee.Set<string> matches = new Gee.HashSet<string>();
        if (query.expression.is_empty) {
            if (!String.is_empty(query.raw) &&
                matches_text_term(
                    email,
                    Convey.SearchQuery.EmailTextTerm.Property.ALL,
                    query.raw
                )) {
                matches.add(query.raw);
            }
            return matches.is_empty ? null : matches;
        }
        foreach (Convey.SearchQuery.Term term in query.expression) {
            Convey.SearchQuery.EmailTextTerm? text =
                term as Convey.SearchQuery.EmailTextTerm;
            if (text == null || term.is_negated) {
                continue;
            }
            foreach (string value in text.terms) {
                if (matches_text_term(email, text.target, value)) {
                    matches.add(value);
                }
            }
        }
        return matches.is_empty ? null : matches;
    }

    private static bool matches_query_term(Convey.Email email, Convey.SearchQuery.Term term) {
        Convey.SearchQuery.EmailTextTerm? text =
            term as Convey.SearchQuery.EmailTextTerm;
        if (text != null) {
            bool any = false;
            foreach (string value in text.terms) {
                if (matches_text_term(email, text.target, value)) {
                    any = true;
                    break;
                }
            }
            return term.is_negated ? !any : any;
        }

        Convey.SearchQuery.EmailFlagTerm? flag =
            term as Convey.SearchQuery.EmailFlagTerm;
        if (flag != null) {
            bool set = (email.email_flags != null &&
                        email.email_flags.contains(flag.value));
            return term.is_negated ? !set : set;
        }
        return true;
    }

    private static bool matches_text_term(Convey.Email email,
                                          Convey.SearchQuery.EmailTextTerm.Property target,
                                          string term) {
        if (String.is_empty(term)) {
            return false;
        }
        string needle = term.down();
        switch (target) {
        case Convey.SearchQuery.EmailTextTerm.Property.TO:
            return matches_addresses_text(email.to, needle);
        case Convey.SearchQuery.EmailTextTerm.Property.CC:
            return matches_addresses_text(email.cc, needle);
        case Convey.SearchQuery.EmailTextTerm.Property.BCC:
            return matches_addresses_text(email.bcc, needle);
        case Convey.SearchQuery.EmailTextTerm.Property.FROM:
            return matches_addresses_text(email.from, needle);
        case Convey.SearchQuery.EmailTextTerm.Property.SUBJECT:
            return matches_subject_text(email.subject, needle);
        case Convey.SearchQuery.EmailTextTerm.Property.BODY:
            return matches_preview_text(email.preview, needle);
        case Convey.SearchQuery.EmailTextTerm.Property.ATTACHMENT_NAME:
            return matches_string_text(email.get_searchable_attachment_list(), needle);
        case Convey.SearchQuery.EmailTextTerm.Property.ALL:
            return (
                matches_subject_text(email.subject, needle) ||
                matches_addresses_text(email.from, needle) ||
                matches_addresses_text(email.to, needle) ||
                matches_addresses_text(email.cc, needle) ||
                matches_addresses_text(email.bcc, needle) ||
                matches_preview_text(email.preview, needle) ||
                matches_string_text(email.get_searchable_attachment_list(), needle)
            );
        default:
            return false;
        }
    }

    private static bool matches_subject_text(Convey.RFC822.Subject? value, string needle) {
        return value != null && value.to_searchable_string().down().contains(needle);
    }

    private static bool matches_preview_text(Convey.RFC822.Text? value, string needle) {
        if (value == null) {
            return false;
        }
        string haystack = ((string) value.buffer.get_bytes().get_data()).make_valid().down();
        return haystack.contains(needle);
    }

    private static bool matches_addresses_text(Convey.RFC822.MailboxAddresses? value, string needle) {
        return value != null && value.to_searchable_string().down().contains(needle);
    }

    private static bool matches_string_text(string? value, string needle) {
        return !String.is_empty(value) && value.down().contains(needle);
    }

    internal void cancel_active_poll() {
        if (this.poll_cancellable != null) {
            this.poll_cancellable.cancel();
            this.poll_cancellable = null;
        }
    }

    /** Returns polling to the fast cadence without an immediate poll. */
    internal void note_user_activity() {
        this.poll_stride = 1;
    }

    internal void trigger_immediate_poll() {
        cancel_active_poll();
        // The user is active: return to the fast poll cadence.
        this.poll_stride = 1;
        // User actions can affect closed folders (e.g. delete moves mail to
        // an unopened Trash), so immediate polls cover cache-loaded folders
        // too, not just open ones. The timer is deliberately not restarted:
        // constant user activity must not starve the periodic full sync.
        queue_folder_poll(true);
    }

    private void on_poll_tick() {
        if (this.screen_locked
            || !GLib.NetworkMonitor.get_default().network_available) {
            debug("Graph: poll tick skipped (locked=%s, network=%s)",
                this.screen_locked.to_string(),
                GLib.NetworkMonitor.get_default().network_available.to_string());
            return;
        }
        this.poll_tick++;
        if (this.poll_tick % FULL_SYNC_EVERY_N_TICKS == 0) {
            debug("Graph: poll tick %u (full sync)", this.poll_tick);
            queue_prefetch_refresh();
        } else if (this.poll_tick % this.poll_stride == 0) {
            debug("Graph: poll tick %u (fast poll, stride %u)",
                this.poll_tick, this.poll_stride);
            queue_folder_poll(false);
        }
    }

    private void queue_folder_poll(bool include_cached) {
        var cancellable = new GLib.Cancellable();
        this.poll_cancellable = cancellable;
        poll_folders_refresh.begin(include_cached, cancellable, (obj, res) => {
            try {
                poll_folders_refresh.end(res);
            } catch (GLib.Error err) {
                if (!(err is GLib.IOError.CANCELLED)) {
                    debug("Graph: folder refresh poll error: %s", err.message);
                }
            }
            if (this.poll_cancellable == cancellable) {
                this.poll_cancellable = null;
            }
        });
    }

    private async void poll_folders_refresh(bool include_cached,
                                            GLib.Cancellable? cancellable)
        throws GLib.Error {
        bool found_changes = false;
        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            if (cancellable != null && cancellable.is_cancelled()) {
                return;
            }
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph == null) {
                continue;
            }
            bool is_open =
                graph.get_open_state() != Convey.Folder.OpenState.CLOSED;
            if (graph.used_as == Convey.Folder.SpecialUse.INBOX) {
                graph.load_persisted_cache();
            } else if (!is_open && !(include_cached && graph.is_cache_loaded)) {
                // The regular poll only covers the inbox and open folders;
                // cache-loaded closed folders sync on the full-sync tick or
                // on immediate (user-action) polls.
                continue;
            }
            try {
                if (yield graph.sync_async(cancellable)) {
                    found_changes = true;
                }
            } catch (GLib.Error err) {
                if (err is GLib.IOError.CANCELLED) {
                    return;
                }
                debug("Graph: folder refresh poll error for %s: %s",
                    graph.path.to_string(), err.message);
            }
        }
        if (!include_cached) {
            // Timer polls drive the cadence: mail flowing → poll every
            // tick; quiet → stretch out to the cap. Immediate polls leave
            // the stride at 1 (set by trigger_immediate_poll).
            this.poll_stride = found_changes
                ? 1 : uint.min(this.poll_stride * 2, MAX_POLL_STRIDE);
        }
    }

    private void queue_prefetch_refresh() {
        if (this.prefetch_refresh_running) {
            this.prefetch_refresh_pending = true;
            return;
        }
        this.prefetch_refresh_running = true;
        refresh_loaded_folders_for_prefetch.begin((obj, res) => {
            try {
                refresh_loaded_folders_for_prefetch.end(res);
            } catch (GLib.Error err) {
                warning("Error refreshing Graph folders after prefetch change: %s", err.message);
            }
            this.prefetch_refresh_running = false;
            if (this.prefetch_refresh_pending) {
                this.prefetch_refresh_pending = false;
                queue_prefetch_refresh();
            }
        });
    }

    private async void refresh_loaded_folders_for_prefetch() throws GLib.Error {
        // Re-sync custom folders on every refresh cycle so that folders created
        // or deleted by another client (e.g. OWA, Outlook) are reflected here.
        if (this.is_account_open) {
            try {
                yield sync_custom_folders_async(null);
            } catch (GLib.Error err) {
                debug("Graph: Failed to sync custom folders during refresh: %s", err.message);
            }
        }

        // When running in background (account closed), only refresh the Inbox
        // to avoid unnecessary work. When account is open, refresh all loaded
        // folders for proper synchronization.
        bool background_mode = !this.is_account_open;

        foreach (Convey.Folder folder in get_remote_folder_snapshot()) {
            Convey.Graph.Folder? graph = folder as Convey.Graph.Folder;
            if (graph == null) {
                continue;
            }

            if (background_mode && graph.used_as != Convey.Folder.SpecialUse.INBOX) {
                continue;
            }

            if (graph.used_as == Convey.Folder.SpecialUse.INBOX) {
                graph.load_persisted_cache();
            }

            // All folders ride this pass — a synced folder costs one
            // near-empty delta response, and never-loaded folders get
            // baselined once so search and threading can see their mail.
            // Folders without delta support get a periodic full listing,
            // their only way to reconcile removals and flag changes.
            try {
                if (graph.is_delta_unsupported) {
                    yield graph.refresh_async(true, null);
                } else {
                    yield graph.sync_async(null);
                }
            } catch (GLib.Error err) {
                debug("Graph: folder refresh error for %s: %s",
                    graph.path.to_string(), err.message);
            }
        }
    }

}

internal class Convey.Graph.SentContactStore : Convey.BaseObject, Convey.ContactStore {

    private unowned Convey.Graph.Account account;

    public SentContactStore(Convey.Graph.Account account) {
        this.account = account;
    }

    public async Convey.Contact? get_by_rfc822(
        Convey.RFC822.MailboxAddress address,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        return null;
    }

    public async Gee.Collection<Convey.Contact> search(
        string query,
        uint min_importance,
        uint limit,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
        var contacts = new Gee.HashMap<string,Convey.Contact>();
        var sent = this.account.get_graph_special_folder(Convey.Folder.SpecialUse.SENT);
        if (sent == null) {
            return contacts.values;
        }
        if (!sent.is_cache_loaded) {
            sent.load_persisted_cache();
        }

        string text = query.replace("%", "").casefold();
        foreach (Convey.Email email in sent.list_cached_emails()) {
            add_matches(contacts, email.to, text);
            add_matches(contacts, email.cc, text);
            add_matches(contacts, email.bcc, text);
        }
        return contacts.values;
    }

    private void add_matches(Gee.Map<string,Convey.Contact> contacts,
                             Convey.RFC822.MailboxAddresses? addresses,
                             string text) {
        if (addresses == null) {
            return;
        }
        foreach (Convey.RFC822.MailboxAddress address in addresses) {
            string name = address.name ?? "";
            if (text in address.address.casefold() || text in name.casefold()) {
                contacts[Convey.Contact.normalise_email(address.address)] =
                    new Convey.Contact.from_rfc822_address(
                        address, Convey.Contact.Importance.SENT_TO
                    );
            }
        }
    }

    public async void update_contacts(
        Gee.Collection<Convey.Contact> updated,
        GLib.Cancellable? cancellable
    ) throws GLib.Error {
    }

}
